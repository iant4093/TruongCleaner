#!/usr/bin/env bash
# Measures the performance budgets P1-P7 (docs/PLAN.md §5) on this Mac.
#   bench.sh            build Release once, run every measurement, print a Markdown table
# Writes JSON lines to build/bench/bench-<timestamp>.jsonl and raw artifacts (samples, tool output)
# to build/bench/run-<timestamp>/. Progress goes to stderr; stdout is the Markdown report.
#
# Read-only: the app is only launched, scanned with and quit. Nothing is cleaned, deleted or moved,
# and no owner command runs. The app is launched with -checkForUpdatesAutomatically <false/> so the
# daily update check does not add network work to the idle numbers (the shipping default is on).
#
# Needs a logged-in GUI session (P1 reads the window list). Close other heavy work first; the load
# average before and after is recorded.
#
# Environment:
#   BENCH_LAUNCH_RUNS        P1 launches (default 5)
#   BENCH_IDLE_WAIT          seconds to wait after launch before P2 sampling (default 10)
#   BENCH_IDLE_SECONDS       P2 CPU sampling period in seconds (default 30)
#   BENCH_FULL_VOLUME_ROOT   root for the P3 scanner walk (default /System/Volumes/Data)
#   BENCH_APP_FULL_VOLUME    1 = also run the app's Space Lens over the Data volume for P3 (default 1)
#   BENCH_SKIP_PACKAGE       1 = skip scripts/package.sh; measure the unsigned build, no dist/ sizes
#   TC_XCODEBUILD_FLAGS      passed to scripts/build.sh (inside the agent sandbox:
#                            OTHER_SWIFT_FLAGS=-disable-sandbox)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

HOME_DIR="$HOME"

LAUNCH_RUNS="${BENCH_LAUNCH_RUNS:-5}"
IDLE_WAIT="${BENCH_IDLE_WAIT:-10}"
IDLE_SECONDS="${BENCH_IDLE_SECONDS:-30}"
VOLUME_ROOT="${BENCH_FULL_VOLUME_ROOT:-/System/Volumes/Data}"
APP_FULL_VOLUME="${BENCH_APP_FULL_VOLUME:-1}"
SKIP_PACKAGE="${BENCH_SKIP_PACKAGE:-0}"
P7_DELAY=2        # seconds after the window appears before the main thread is sampled
P7_SAMPLE=4       # seconds sampled
SCAN_MAX=600      # longest app scan we wait for, in seconds

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$ROOT/build/bench"
RUN_DIR="$OUT_DIR/run-$STAMP"
JSONL="$OUT_DIR/bench-$STAMP.jsonl"
TABLE="$RUN_DIR/table.txt"
DETAILS="$RUN_DIR/details.txt"
BT="$OUT_DIR/bin/benchtool"
mkdir -p "$RUN_DIR" "$OUT_DIR/bin" "$ROOT/build/logs"
: >"$JSONL"
: >"$TABLE"
: >"$DETAILS"

say() { printf '== %s\n' "$*" >&2; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------- small helpers (bash 3.2 compatible) ----------

# jnum <json> <key>: the number after "key": in a one-line JSON object, or empty.
jnum() { printf '%s' "$1" | sed -nE "s/.*\"$2\":(-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?).*/\1/p" | head -1; }
# jbool <json> <key>: true or false, or empty.
jbool() { printf '%s' "$1" | sed -nE "s/.*\"$2\":(true|false).*/\1/p" | head -1; }

median() { printf '%s\n' "$@" | sort -g | awk '{a[NR]=$1} END{if(NR==0){exit} if(NR%2){print a[(NR+1)/2]} else {printf "%.6g\n",(a[NR/2]+a[NR/2+1])/2}}'; }
maxof() { printf '%s\n' "$@" | sort -g | tail -1; }
minof() { printf '%s\n' "$@" | sort -g | head -1; }
# calc "<awk expression>": prints the value with 6 significant digits.
calc() { awk "BEGIN{printf \"%.6g\", $1}"; }
# fmt <format> <number>
fmt() { awk -v v="$2" "BEGIN{printf \"$1\", v}"; }
mib() { awk -v v="$1" 'BEGIN{printf "%.1f MiB", v/1048576}'; }
is_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }
is_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}'; }

# row <id> <budget> <measured> <result>: one line of the Markdown table.
row() { printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" >>"$TABLE"; }
detail() { printf '%s\n' "$*" >>"$DETAILS"; }
# record <json object>: one line of the JSONL file.
record() { printf '%s\n' "$1" >>"$JSONL"; }
verdict() { if "$@"; then printf 'PASS'; else printf 'FAIL'; fi; }

# ext_note <analysis json>: a sentence when the sample holds accessibility-client work (for example an
# XCTest run on this Mac inspecting the app). Those samples are not counted as the app's own work.
ext_note() {
  local n
  n="$(jnum "$1" mainThreadExternalSamples)"
  if [ -n "$n" ] && [ "$n" != 0 ]; then printf '; %s samples were accessibility requests from another tool and are not counted' "$n"; fi
}

# json_list <numbers...> -> [1,2,3]
json_list() { local out="" n; for n in "$@"; do out="${out:+$out,}$n"; done; printf '[%s]' "$out"; }

# run_timed <outfile> <command...>: runs with /usr/bin/time -l. Sets T_REAL (seconds), T_RSS (bytes),
# T_PEAKFP (bytes) and T_RC. stdout goes to <outfile>, stderr to <outfile>.err.
T_REAL=""; T_RSS=""; T_PEAKFP=""; T_RC=0
run_timed() {
  local out="$1"
  shift
  /usr/bin/time -l -o "$out.time" "$@" >"$out" 2>"$out.err"
  T_RC=$?
  T_REAL="$(awk '/ real /{print $1; exit}' "$out.time")"
  T_RSS="$(awk '/maximum resident set size/{print $1; exit}' "$out.time")"
  T_PEAKFP="$(awk '/peak memory footprint/{print $1; exit}' "$out.time")"
}

# tc_val <file> <label> [numeric field index]: value of a "label   value" line from tcbench output.
tc_val() { sed -nE "s/^$2 +//p" "$1" | head -1; }
tc_num() { tc_val "$1" "$2" | awk '{print $1}'; }

# ---------- app lifecycle ----------

APP=""
APP_PID=""
APP_ARGS=(-checkForUpdatesAutomatically '<false/>')
BG_PIDS=""

launch_app() { # launch_app [extra app arguments...]; sets APP_PID and LAUNCH_JSON
  LAUNCH_JSON="$("$BT" launch "$APP" --timeout 20 -- "${APP_ARGS[@]}" "$@")"
  local status=$?
  APP_PID="$(jnum "$LAUNCH_JSON" pid)"
  if [ $status -ne 0 ]; then
    printf '%s\n' "$LAUNCH_JSON" >&2
    return 1
  fi
  return 0
}

quit_app() {
  if [ -n "$APP_PID" ]; then
    "$BT" quit "$APP_PID" "$APP" >/dev/null 2>&1
    APP_PID=""
  fi
}

cleanup() {
  quit_app
  local pid
  for pid in $BG_PIDS; do kill "$pid" 2>/dev/null; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- build ----------

say "build (Release app, tcbench, helper)"
if ! bash scripts/build.sh release >"$RUN_DIR/build.log" 2>&1; then
  tail -20 "$RUN_DIR/build.log" >&2
  die "scripts/build.sh release failed (log: $RUN_DIR/build.log)"
fi
DERIVED_APP="$ROOT/build/ReleaseDerivedData/Build/Products/Release/TruongCleaner.app"
APP="$DERIVED_APP"
if [ "$SKIP_PACKAGE" != 1 ]; then
  if ! bash scripts/package.sh >"$RUN_DIR/package.log" 2>&1; then
    tail -20 "$RUN_DIR/package.log" >&2
    die "scripts/package.sh failed (log: $RUN_DIR/package.log)"
  fi
  APP="$ROOT/build/package/TruongCleaner.app"
fi
[ -d "$APP" ] || die "app not found at $APP"

swift build -c release --disable-sandbox --package-path Packages/CleanerKit --scratch-path build/swiftpm \
  --product tcbench >"$RUN_DIR/tcbench-build.log" 2>&1 || {
  tail -20 "$RUN_DIR/tcbench-build.log" >&2
  die "tcbench build failed"
}
TCBENCH="$(swift build -c release --disable-sandbox --package-path Packages/CleanerKit --scratch-path build/swiftpm \
  --show-bin-path 2>/dev/null)/tcbench"
[ -x "$TCBENCH" ] || die "tcbench not found at $TCBENCH"

if [ ! -x "$BT" ] || [ scripts/bench/benchtool.swift -nt "$BT" ]; then
  swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors -o "$BT" scripts/bench/benchtool.swift \
    >"$RUN_DIR/benchtool-build.log" 2>&1 || {
    tail -20 "$RUN_DIR/benchtool-build.log" >&2
    die "benchtool build failed"
  }
fi

# ---------- environment ----------

PLIST="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null)"
LOAD_BEFORE="$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1" "$2" "$3}')"
CHIP="$(sysctl -n machdep.cpu.brand_string)"
CPUS="$(sysctl -n hw.ncpu)"
MEM_GB="$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')"
MACOS="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
record "{\"meta\":{\"date\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"chip\":\"$CHIP\",\"cpus\":$CPUS,\"memoryGB\":$MEM_GB,\"macOS\":\"$MACOS\",\"app\":\"$VERSION ($BUILD)\",\"appPath\":\"${APP#"$ROOT"/}\",\"commit\":\"$COMMIT\",\"loadBefore\":\"$LOAD_BEFORE\"}}"

# ---------- P1: cold launch to first window ----------

say "P1: launch to first window ($LAUNCH_RUNS runs)"
P1_RUNS=""
i=1
while [ "$i" -le "$LAUNCH_RUNS" ]; do
  if launch_app; then
    ms="$(jnum "$LAUNCH_JSON" windowMs)"
    P1_RUNS="$P1_RUNS $(fmt '%.1f' "$ms")"
    say "  run $i: $(fmt '%.0f' "$ms") ms"
    quit_app
    sleep 1
  else
    say "  run $i: no window"
  fi
  i=$((i + 1))
done
# shellcheck disable=SC2086
if [ -n "$P1_RUNS" ]; then
  P1_MED="$(median $P1_RUNS)"
  P1_MAX="$(maxof $P1_RUNS)"
  P1_OK="$(verdict is_lt "$P1_MED" 400)"
  record "{\"id\":\"P1\",\"metric\":\"launchToFirstWindowMs\",\"runs\":$(json_list $P1_RUNS),\"median\":$P1_MED,\"max\":$P1_MAX,\"budgetMs\":400,\"result\":\"$P1_OK\"}"
  row P1 "launch to first window < 400 ms" "median $(fmt '%.0f' "$P1_MED") ms, max $(fmt '%.0f' "$P1_MAX") ms (runs:$(printf ' %.0f' $P1_RUNS))" "$P1_OK"
else
  row P1 "launch to first window < 400 ms" "no window appeared (no GUI session?)" "NOT MEASURED"
  record '{"id":"P1","result":"NOT MEASURED"}'
fi
detail "P1: window = first on-screen layer-0 window of the app at least 300x200 pt; time from just before 'open -n' to the poll (10 ms) that sees it. Page cache is warm after the build, so run 1 is not a true cold boot launch (no sudo purge)."

# ---------- P2 and P3 (idle): one launch, left alone ----------

# The Overview page starts a category measurement of the home folder by itself when the app opens, so
# the app is busy for a while after launch. We record that launch work, wait until the app is quiet,
# and then measure true idle (CPU for IDLE_SECONDS, an idle 'sample', memory).
say "P2/P3: idle launch (settle, wait ${IDLE_WAIT}s, sample CPU ${IDLE_SECONDS}s)"
IDLE_OK=0
LAUNCH_PEAK=0
if launch_app; then
  SETTLE_JSON="$("$BT" settle "$APP_PID" --max 180)"
  sleep "$IDLE_WAIT"
  "$BT" usage "$APP_PID" "$IDLE_SECONDS" >"$RUN_DIR/idle-usage.json" &
  USAGE_JOB=$!
  BG_PIDS="$BG_PIDS $USAGE_JOB"
  : >"$RUN_DIR/idle-ps.txt"
  s=0
  while [ "$s" -lt "$IDLE_SECONDS" ]; do
    ps -o %cpu= -p "$APP_PID" >>"$RUN_DIR/idle-ps.txt" 2>/dev/null
    sleep 1
    s=$((s + 1))
  done
  wait "$USAGE_JOB"
  IDLE_USAGE="$(cat "$RUN_DIR/idle-usage.json")"
  sample "$APP_PID" 3 1 -file "$RUN_DIR/idle-sample.txt" >/dev/null 2>&1
  IDLE_ANALYSIS="$("$BT" analyze "$RUN_DIR/idle-sample.txt")"
  footprint "$APP_PID" >"$RUN_DIR/idle-footprint.txt" 2>&1
  [ -n "$(jnum "$SETTLE_JSON" activeMs)" ] && [ -n "$(jnum "$IDLE_USAGE" cpuMeanPercent)" ] && IDLE_OK=1
  quit_app
else
  say "  could not launch for the idle measurement"
fi

if [ "$IDLE_OK" = 1 ]; then
  CPU_MEAN="$(jnum "$IDLE_USAGE" cpuMeanPercent)"
  CPU_MAX="$(jnum "$IDLE_USAGE" cpuMaxPercent)"
  WAKEUPS="$(jnum "$IDLE_USAGE" wakeupsPerSecond)"
  IDLE_FP="$(jnum "$IDLE_USAGE" footprintBytes)"
  LAUNCH_PEAK="$(jnum "$IDLE_USAGE" peakFootprintBytes)"
  ACTIVE_MS="$(jnum "$SETTLE_JSON" activeMs)"
  ACTIVE_CPU="$(jnum "$SETTLE_JSON" cpuSecondsUntilQuiet)"
  TIMER_COUNT="$(printf '%s' "$IDLE_ANALYSIS" | grep -o '"timerFrames":\[[^]]*\]' | grep -o '"frame"' | wc -l | tr -d ' ')"
  IDLE_BUSY="$(jnum "$IDLE_ANALYSIS" mainThreadBusySamples)"
  PS_COUNT="$(grep -c . "$RUN_DIR/idle-ps.txt")"
  if [ "$PS_COUNT" -gt 0 ]; then
    PS_MEAN="$(awk '{s+=$1} END{printf "%.3f", s/NR}' "$RUN_DIR/idle-ps.txt")"
    PS_MAX="$(sort -g "$RUN_DIR/idle-ps.txt" | tail -1)"
  else
    PS_MEAN="n/a"
    PS_MAX="n/a"
  fi
  P2_WHY=""
  P2_OK=PASS
  if ! { is_lt "$CPU_MEAN" 0.1 && is_lt "$CPU_MAX" 1; }; then P2_OK=FAIL; P2_WHY="idle CPU too high; "; fi
  if [ "$TIMER_COUNT" != 0 ]; then P2_OK=FAIL; P2_WHY="${P2_WHY}timer frames while idle; "; fi
  if ! is_le "$ACTIVE_CPU" 1; then P2_OK=FAIL; P2_WHY="${P2_WHY}background work after launch ($(fmt '%.0f' "$ACTIVE_CPU") CPU-s, no user action); "; fi
  record "{\"id\":\"P2\",\"metric\":\"idleCpu\",\"cpuMeanPercent\":$CPU_MEAN,\"cpuMaxPercent\":$CPU_MAX,\"wakeupsPerSecond\":$WAKEUPS,\"psMeanPercent\":\"$PS_MEAN\",\"psMaxPercent\":\"$PS_MAX\",\"timerFramesInSample\":$TIMER_COUNT,\"mainThreadBusySamplesInIdleSample\":$IDLE_BUSY,\"seconds\":$IDLE_SECONDS,\"launchWorkMs\":$ACTIVE_MS,\"launchWorkCpuSeconds\":$ACTIVE_CPU,\"result\":\"$P2_OK\"}"
  row P2 "idle: 0% CPU, no timers, no background scanning" "after launch the app worked for $(fmt '%.1f' "$(calc "$ACTIVE_MS / 1000")") s using $(fmt '%.1f' "$ACTIVE_CPU") CPU-s with no user action; then idle: CPU mean $(fmt '%.3f' "$CPU_MEAN")%, max $(fmt '%.2f' "$CPU_MAX")% over ${IDLE_SECONDS}s, $(fmt '%.1f' "$WAKEUPS") wakeups/s, timer frames in 3 s sample: $TIMER_COUNT, ps %cpu mean $PS_MEAN" "$P2_OK${P2_WHY:+ (${P2_WHY%; })}"
  detail "P2: pass = no launch work above 1 CPU-s, then rusage CPU mean < 0.1% and max < 1%, and no timer frames in the idle 'sample'. Brief deviation: the 10 s wait is applied after the app has been quiet for 5 s ('benchtool settle'), because the default launch (Overview page) starts its own scan. ps %cpu is a decayed average since launch on macOS (reported, not used for the verdict); 'n/a' = ps is not allowed here. Idle sample: ${RUN_DIR#"$ROOT"/}/idle-sample.txt"
  detail "P2 idle sample analysis: $IDLE_ANALYSIS"

  if is_lt "$IDLE_FP" $((60 * 1048576)); then P3_IDLE_OK=PASS; else P3_IDLE_OK=FAIL; fi
  FP_LINE="$(grep -m1 'Footprint:' "$RUN_DIR/idle-footprint.txt" | sed -E 's/^.*Footprint: //')"
  record "{\"id\":\"P3\",\"metric\":\"idleFootprintBytes\",\"bytes\":$IDLE_FP,\"peakFootprintSinceLaunchBytes\":$LAUNCH_PEAK,\"footprintTool\":\"$FP_LINE\",\"budgetBytes\":$((60 * 1048576)),\"result\":\"$P3_IDLE_OK\"}"
  row "P3 idle" "memory idle < 60 MiB" "footprint $(mib "$IDLE_FP") at idle (footprint tool: $FP_LINE); lifetime peak since launch $(mib "$LAUNCH_PEAK") (the launch scan runs)" "$P3_IDLE_OK"
else
  row P2 "idle: 0% CPU, no timers, no background scanning" "app did not launch or settle" "NOT MEASURED"
  row "P3 idle" "memory idle < 60 MiB" "app did not launch or settle" "NOT MEASURED"
fi

# ---------- P3 (scan): scanner walk and the app's own scan ----------

say "P3: tcbench walk $VOLUME_ROOT (8 workers)"
run_timed "$RUN_DIR/walk-volume.txt" "$TCBENCH" walk "$VOLUME_ROOT" --workers 8
if [ "$T_RC" -eq 0 ]; then
  VOL_FILES="$(tc_num "$RUN_DIR/walk-volume.txt" files)"
  VOL_DENIED="$(tc_num "$RUN_DIR/walk-volume.txt" 'denied folders')"
  VOL_ALLOC="$(sed -nE 's/^allocated +([0-9]+) bytes.*/\1/p' "$RUN_DIR/walk-volume.txt" | head -1)"
  if is_lt "$T_RSS" $((250 * 1048576)); then P3W_OK=PASS; else P3W_OK=FAIL; fi
  record "{\"id\":\"P3\",\"metric\":\"scannerWalkPeakRssBytes\",\"root\":\"$VOLUME_ROOT\",\"peakRssBytes\":$T_RSS,\"peakFootprintBytes\":${T_PEAKFP:-0},\"seconds\":$T_REAL,\"files\":$VOL_FILES,\"deniedFolders\":$VOL_DENIED,\"allocatedBytes\":$VOL_ALLOC,\"budgetBytes\":$((250 * 1048576)),\"result\":\"$P3W_OK\"}"
  row "P3 scan (walker)" "memory during full Data-volume scan < 250 MiB" "tcbench walk: peak RSS $(mib "$T_RSS"), peak footprint $(mib "${T_PEAKFP:-0}"); $VOL_FILES files in ${T_REAL} s; $VOL_DENIED folders denied" "$P3W_OK"
else
  tail -5 "$RUN_DIR/walk-volume.txt.err" >&2
  row "P3 scan (walker)" "memory during full Data-volume scan < 250 MiB" "tcbench walk failed (exit $T_RC)" "NOT MEASURED"
fi

# app_scan <label> <start page> <extra args...>: launches with a scan, waits until it goes quiet.
# Sets SCAN_JSON. Optionally samples the main thread (P7) when SAMPLE_FILE is set.
app_scan() {
  local page="$1"
  shift
  SCAN_JSON=""
  launch_app -TCStartPage "$page" -TCAutoScan YES "$@" || { SCAN_JSON="$LAUNCH_JSON"; return 1; }
  "$BT" watch "$APP_PID" --max "$SCAN_MAX" --min 4 --start-timeout 30 >"$RUN_DIR/scan-watch.json" &
  local watch_job=$!
  BG_PIDS="$BG_PIDS $watch_job"
  if [ -n "${SAMPLE_FILE:-}" ]; then
    sleep "$P7_DELAY"
    sample "$APP_PID" "$P7_SAMPLE" 1 -file "$SAMPLE_FILE" >/dev/null 2>&1
  fi
  wait "$watch_job"
  SCAN_JSON="$(cat "$RUN_DIR/scan-watch.json")"
  FOOTPRINT_NOW="$(footprint "$APP_PID" 2>&1 | grep -m1 'Footprint:' | sed -E 's/^.*Footprint: //')"
  quit_app
}

say "P3/P4/P7: app Smart Clean scan with main-thread sample"
SAMPLE_FILE="$RUN_DIR/smartclean-sample.txt"
P7_OK="NOT MEASURED"
if app_scan smartClean && [ -n "$(jnum "$SCAN_JSON" busyMs)" ]; then
  SC_BUSY="$(jnum "$SCAN_JSON" busyMs)"
  SC_START="$(jnum "$SCAN_JSON" startedAfterMs)"
  SC_PEAK="$(jnum "$SCAN_JSON" lifetimePeakAtEndBytes)"
  SC_OBS="$(jnum "$SCAN_JSON" observedPeakBytes)"
  SC_ANALYSIS="$("$BT" analyze "$SAMPLE_FILE")"
  MAIN_TOTAL="$(jnum "$SC_ANALYSIS" mainThreadSamples)"
  MAIN_BUSY="$(jnum "$SC_ANALYSIS" mainThreadBusySamples)"
  MAIN_SHARE="$(jnum "$SC_ANALYSIS" mainThreadBusyShare)"
  SC_EXT="$(ext_note "$SC_ANALYSIS")"
  BUSY_MS="$(calc "$MAIN_SHARE * $P7_SAMPLE * 1000")"
  TOPS="$(printf '%s' "$SC_ANALYSIS" | grep -o '"topBusyFrames":\[[^]]*\]' | grep -o '"frame":"[^"]*"' | head -3 | sed -E 's/"frame":"//; s/"$//' | tr '\n' ';')"
  if is_lt "$((${SC_START%.*} + ${SC_BUSY%.*}))" $(((P7_DELAY + 1) * 1000)); then
    P7_OK="INCONCLUSIVE (scan ended before the sample)"
  elif is_le "$BUSY_MS" 16; then
    P7_OK=PASS
  else
    P7_OK="REVIEW"
  fi
  record "{\"id\":\"P7\",\"metric\":\"mainThreadBusyDuringSmartCleanScan\",\"sampleSeconds\":$P7_SAMPLE,\"delaySeconds\":$P7_DELAY,\"mainThreadSamples\":$MAIN_TOTAL,\"busySamples\":$MAIN_BUSY,\"busyShare\":$MAIN_SHARE,\"estimatedBusyMs\":$BUSY_MS,\"scanBusyMs\":$SC_BUSY,\"scanStartedAfterMs\":$SC_START,\"analysis\":$SC_ANALYSIS,\"result\":\"$P7_OK\"}"
  row P7 "no main-thread work > 16 ms during a scan" "app busy ${SC_BUSY%.*} ms after launch with the Smart Clean scan running (the launch scan overlaps): main thread outside waiting in $(fmt '%.1f' "$(calc "$MAIN_SHARE * 100")")% of ${MAIN_TOTAL} samples (about $(fmt '%.0f' "$BUSY_MS") ms of ${P7_SAMPLE} s); top: ${TOPS:-none}$SC_EXT" "$P7_OK"
  detail "P3/P4/P7 (app scans): the app starts its own home-folder category scan at launch whatever page is chosen (a History-page launch shows CategoryScanner.measure in 'sample'), so a page scan started by -TCAutoScan overlaps it and the two cannot be told apart. The launch-only baseline is the P2/P3 idle run. The scanner's own P3 and P4 numbers come from tcbench."
detail "P7: sample taken ${P7_DELAY} s after the window appeared, ${P7_SAMPLE} s long (1 ms interval requested). PASS = estimated main-thread busy time <= 16 ms in total, which proves no single stall > 16 ms. Above that, 'sample' cannot tell one long stall from many short bursts, so the result is REVIEW with the top busy frames. Sample: $SAMPLE_FILE"
  record "{\"id\":\"P4\",\"metric\":\"appSmartCleanScanBusyMs\",\"startedAfterMs\":$SC_START,\"busyMs\":$SC_BUSY,\"footprintAfter\":\"$FOOTPRINT_NOW\",\"lifetimePeakFootprintBytes\":$SC_PEAK,\"observedPeakFootprintBytes\":$SC_OBS}"
  detail "P4 (app): Smart Clean scan, window busy period $(fmt '%.0f' "$SC_BUSY") ms (starts $(fmt '%.0f' "$SC_START") ms after window); lifetime peak footprint $(mib "$SC_PEAK") (launch alone peaked at $(mib "$LAUNCH_PEAK"))."
else
  say "  Smart Clean scan did not run: $SCAN_JSON"
  row P7 "no main-thread work > 16 ms during a scan" "app scan failed: $SCAN_JSON" "NOT MEASURED"
fi
SAMPLE_FILE=""

say "P3/P7: app Space Lens scan of $HOME_DIR/Library with main-thread sample"
SAMPLE_FILE="$RUN_DIR/spacelens-sample.txt"
if app_scan spaceLens -TCLensRoot "$HOME_DIR/Library" && [ -n "$(jnum "$SCAN_JSON" busyMs)" ]; then
  SL_BUSY="$(jnum "$SCAN_JSON" busyMs)"
  SL_PEAK="$(jnum "$SCAN_JSON" lifetimePeakAtEndBytes)"
  SL_ANALYSIS="$("$BT" analyze "$SAMPLE_FILE")"
  SL_SHARE="$(jnum "$SL_ANALYSIS" mainThreadBusyShare)"
  SL_EXT="$(ext_note "$SL_ANALYSIS")"
  SL_TOTAL="$(jnum "$SL_ANALYSIS" mainThreadSamples)"
  SL_BUSY_MS="$(calc "$SL_SHARE * $P7_SAMPLE * 1000")"
  SL_TOPS="$(printf '%s' "$SL_ANALYSIS" | grep -o '"topBusyFrames":\[[^]]*\]' | grep -o '"frame":"[^"]*"' | head -3 | sed -E 's/"frame":"//; s/"$//' | tr '\n' ';')"
  if is_lt "$SL_BUSY" $(((P7_DELAY + 1) * 1000)); then SL_P7="INCONCLUSIVE (scan ended before the sample)"
  elif is_le "$SL_BUSY_MS" 16; then SL_P7=PASS; else SL_P7=REVIEW; fi
  if is_lt "$SL_PEAK" $((250 * 1048576)); then SL_OK=PASS; else SL_OK=FAIL; fi
  record "{\"id\":\"P3\",\"metric\":\"appSpaceLensScanPeakFootprintBytes\",\"root\":\"~/Library\",\"scanBusyMs\":$SL_BUSY,\"lifetimePeakFootprintBytes\":$SL_PEAK,\"launchPeakFootprintBytes\":$LAUNCH_PEAK,\"footprintAfter\":\"$FOOTPRINT_NOW\",\"budgetBytes\":$((250 * 1048576)),\"result\":\"$SL_OK\"}"
  record "{\"id\":\"P7\",\"metric\":\"mainThreadBusyDuringSpaceLensScan\",\"mainThreadSamples\":$SL_TOTAL,\"busyShare\":$SL_SHARE,\"estimatedBusyMs\":$SL_BUSY_MS,\"scanBusyMs\":$SL_BUSY,\"analysis\":$SL_ANALYSIS,\"result\":\"$SL_P7\"}"
  row "P3 scan (app, ~/Library)" "memory during a scan < 250 MiB" "app busy $(fmt '%.0f' "$(calc "$SL_BUSY / 1000")") s with Space Lens over ~/Library: lifetime peak footprint $(mib "$SL_PEAK"); launch alone (no page scan) peaked at $(mib "$LAUNCH_PEAK")" "$SL_OK"
  row "P7 (Space Lens)" "no main-thread work > 16 ms during a scan" "main thread outside waiting in $(fmt '%.1f' "$(calc "$SL_SHARE * 100")")% of ${SL_TOTAL} samples (about $(fmt '%.0f' "$SL_BUSY_MS") ms of ${P7_SAMPLE} s); top: ${SL_TOPS:-none}$SL_EXT" "$SL_P7"
else
  say "  Space Lens scan did not run: $SCAN_JSON"
  row "P3 scan (app, ~/Library)" "memory during a scan < 250 MiB" "app scan failed: $SCAN_JSON" "NOT MEASURED"
fi
SAMPLE_FILE=""

if [ "$APP_FULL_VOLUME" = 1 ]; then
  say "P3: app Space Lens scan of $VOLUME_ROOT (up to ${SCAN_MAX}s)"
  if app_scan spaceLens -TCLensRoot "$VOLUME_ROOT" && [ -n "$(jnum "$SCAN_JSON" busyMs)" ]; then
    FV_BUSY="$(jnum "$SCAN_JSON" busyMs)"
    FV_PEAK="$(jnum "$SCAN_JSON" lifetimePeakAtEndBytes)"
    FV_TIMEOUT="$(jbool "$SCAN_JSON" timedOut)"
    if is_lt "$FV_PEAK" $((250 * 1048576)); then FV_OK=PASS; else FV_OK=FAIL; fi
    record "{\"id\":\"P3\",\"metric\":\"appFullVolumeScanPeakFootprintBytes\",\"root\":\"$VOLUME_ROOT\",\"scanBusyMs\":$FV_BUSY,\"timedOut\":$FV_TIMEOUT,\"lifetimePeakFootprintBytes\":$FV_PEAK,\"footprintAfter\":\"$FOOTPRINT_NOW\",\"budgetBytes\":$((250 * 1048576)),\"result\":\"$FV_OK\"}"
    row "P3 scan (app, Data volume)" "memory during full Data-volume scan < 250 MiB" "app busy $(fmt '%.0f' "$(calc "$FV_BUSY / 1000")") s$([ "$FV_TIMEOUT" = true ] && echo " (hit the ${SCAN_MAX} s limit)") with Space Lens over $VOLUME_ROOT: lifetime peak footprint $(mib "$FV_PEAK"); launch alone peaked at $(mib "$LAUNCH_PEAK"); footprint afterwards $FOOTPRINT_NOW" "$FV_OK"
  else
    say "  full-volume app scan did not run: $SCAN_JSON"
    row "P3 scan (app, Data volume)" "memory during full Data-volume scan < 250 MiB" "app scan failed: $SCAN_JSON" "NOT MEASURED"
  fi
fi

# ---------- P4: Smart Clean scan time, warm ----------

say "P4: tcbench smartclean $HOME_DIR (1 warm-up + 3 runs)"
run_timed "$RUN_DIR/smartclean-warmup.txt" "$TCBENCH" smartclean "$HOME_DIR"
P4_RUNS=""
i=1
while [ "$i" -le 3 ]; do
  run_timed "$RUN_DIR/smartclean-$i.txt" "$TCBENCH" smartclean "$HOME_DIR"
  if [ "$T_RC" -eq 0 ]; then
    wall="$(tc_num "$RUN_DIR/smartclean-$i.txt" 'wall seconds')"
    P4_RUNS="$P4_RUNS $wall"
    say "  run $i: ${wall} s"
  fi
  i=$((i + 1))
done
# shellcheck disable=SC2086
if [ -n "$P4_RUNS" ]; then
  P4_MED="$(median $P4_RUNS)"
  P4_MAX="$(maxof $P4_RUNS)"
  P4_RULES="$(tc_val "$RUN_DIR/smartclean-1.txt" rules)"
  P4_FILES="$(tc_num "$RUN_DIR/smartclean-1.txt" 'files counted')"
  P4_SLOW="$(sed -nE 's/^slow rule +//p' "$RUN_DIR/smartclean-1.txt" | head -3 | tr '\n' ';')"
  P4_RSS="$(tc_num "$RUN_DIR/smartclean-1.txt" 'peak memory bytes')"
  P4_OK="$(verdict is_lt "$P4_MED" 5)"
  record "{\"id\":\"P4\",\"metric\":\"smartCleanScanSeconds\",\"runs\":$(json_list $P4_RUNS),\"median\":$P4_MED,\"max\":$P4_MAX,\"files\":$P4_FILES,\"peakRssBytes\":$P4_RSS,\"budgetSeconds\":5,\"result\":\"$P4_OK\"}"
  row P4 "Smart Clean scan, warm < 5 s" "median $(fmt '%.2f' "$P4_MED") s, max $(fmt '%.2f' "$P4_MAX") s (runs:$P4_RUNS); $P4_FILES files; rules: $P4_RULES; slowest: $P4_SLOW" "$P4_OK"
  detail "P4: 'tcbench smartclean' runs the rules the Smart Clean page offers (Settings not read: nothing excluded or turned off). Wall time of ScanEngine, one process per run, after one discarded warm-up run."
else
  row P4 "Smart Clean scan, warm < 5 s" "tcbench smartclean failed" "NOT MEASURED"
fi

# ---------- P5: throughput vs du ----------

P5_ROOT="$HOME_DIR/Library"
say "P5: tcbench walk vs du -skx on $P5_ROOT (1 warm-up + 3 runs each)"
run_timed "$RUN_DIR/p5-warmup.txt" "$TCBENCH" walk "$P5_ROOT" --workers 8
W_RUNS=""
D_RUNS=""
i=1
while [ "$i" -le 3 ]; do
  run_timed "$RUN_DIR/p5-walk-$i.txt" "$TCBENCH" walk "$P5_ROOT" --workers 8
  W_RUNS="$W_RUNS $T_REAL"
  run_timed "$RUN_DIR/p5-du-$i.txt" /usr/bin/du -skx "$P5_ROOT"
  D_RUNS="$D_RUNS $T_REAL"
  say "  run $i: tcbench ${W_RUNS##* } s, du ${D_RUNS##* } s"
  i=$((i + 1))
done
# shellcheck disable=SC2086
W_MED="$(median $W_RUNS)"
# shellcheck disable=SC2086
D_MED="$(median $D_RUNS)"
P5_FILES="$(tc_num "$RUN_DIR/p5-walk-1.txt" files)"
P5_DENIED="$(tc_num "$RUN_DIR/p5-walk-1.txt" 'denied folders')"
P5_ALLOC="$(sed -nE 's/^allocated +([0-9]+) bytes.*/\1/p' "$RUN_DIR/p5-walk-1.txt" | head -1)"
P5_DU_KB="$(awk '{print $1; exit}' "$RUN_DIR/p5-du-1.txt")"
P5_FPS="$(calc "$P5_FILES / $W_MED")"
P5_DU_FPS="$(calc "$P5_FILES / $D_MED")"
P5_SPEEDUP="$(calc "$D_MED / $W_MED")"
P5_OK="$(verdict is_lt "$W_MED" "$D_MED")"
# shellcheck disable=SC2086
record "{\"id\":\"P5\",\"metric\":\"walkVsDu\",\"root\":\"~/Library\",\"files\":$P5_FILES,\"tcbenchSeconds\":$(json_list $W_RUNS),\"duSeconds\":$(json_list $D_RUNS),\"tcbenchMedian\":$W_MED,\"duMedian\":$D_MED,\"tcbenchFilesPerSecond\":$P5_FPS,\"duFilesPerSecond\":$P5_DU_FPS,\"speedup\":$P5_SPEEDUP,\"tcbenchAllocatedBytes\":$P5_ALLOC,\"duKilobytes\":${P5_DU_KB:-0},\"deniedFolders\":$P5_DENIED,\"result\":\"$P5_OK\"}"
row P5 "throughput at least that of du -sk" "tcbench walk median ${W_MED} s ($(fmt '%.0f' "$P5_FPS") files/s) vs du -skx ${D_MED} s ($(fmt '%.0f' "$P5_DU_FPS") files/s): $(fmt '%.1f' "$P5_SPEEDUP")x; ~/Library, $P5_FILES files" "$P5_OK"
detail "P5: shipping BulkWalker via 'tcbench walk' (8 workers) against 'du -skx', same tree, warm cache. du files/s uses the walker's file count. Totals: tcbench allocated $P5_ALLOC bytes, du ${P5_DU_KB:-?} KB (du counts folders and skips what it cannot read; $P5_DENIED folders were denied to the walker). spikes/s1-walker was not rerun: P5 is about the shipping walker."

# ---------- P6: bundle size ----------

say "P6: sizes"
size_kb() { du -sk "$1" | awk '{print $1}'; }
logical_bytes() { find "$1" -type f -exec stat -f %z {} + | awk '{s+=$1} END{print s+0}'; }
APP_KB="$(size_kb "$APP")"
APP_LOGICAL="$(logical_bytes "$APP")"
if is_lt "$APP_KB" 5120; then P6_OK=PASS; else P6_OK=FAIL; fi
DIST_TEXT=""
if [ "$SKIP_PACKAGE" != 1 ] && [ -d "$ROOT/dist" ]; then
  for f in TruongCleaner.zip TruongCleaner.dmg TruongCleaner.dSYM.zip install.sh; do
    [ -f "$ROOT/dist/$f" ] && DIST_TEXT="$DIST_TEXT $f=$(stat -f %z "$ROOT/dist/$f")"
  done
fi
record "{\"id\":\"P6\",\"metric\":\"bundleSize\",\"appDiskUsageKB\":$APP_KB,\"appLogicalBytes\":$APP_LOGICAL,\"dist\":\"${DIST_TEXT# }\",\"budgetKB\":5120,\"result\":\"$P6_OK\"}"
row P6 "app bundle < 5 MiB" "$(awk -v k="$APP_KB" 'BEGIN{printf "%.2f MiB", k/1024}') on disk (du -sk), $APP_LOGICAL bytes of files; dist (bytes):${DIST_TEXT:- not built}" "$P6_OK"
detail "P6: app measured: ${APP#"$ROOT"/}"

# ---------- report ----------

LOAD_AFTER="$(sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1" "$2" "$3}')"
record "{\"meta\":{\"loadAfter\":\"$LOAD_AFTER\"}}"

{
  echo "## Performance budgets"
  echo
  echo "- Date: $(date '+%Y-%m-%d %H:%M')  Commit: $COMMIT  App: TruongCleaner $VERSION ($BUILD), Release, $([ "$SKIP_PACKAGE" = 1 ] && echo unsigned || echo ad-hoc signed)"
  echo "- Mac: $CHIP, $CPUS cores, ${MEM_GB} GB, macOS $MACOS"
  echo "- Load average (1/5/15 min) before: $LOAD_BEFORE; after: $LOAD_AFTER"
  echo "- Raw data: ${JSONL#"$ROOT"/} and ${RUN_DIR#"$ROOT"/}/"
  echo
  echo "| ID | Budget | Measured | Result |"
  echo "|---|---|---|---|"
  cat "$TABLE"
  echo
  echo "Notes"
  echo
  sed 's/^/- /' "$DETAILS"
}

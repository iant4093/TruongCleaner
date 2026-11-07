#!/usr/bin/env bash
# Spike S3: Trash behavior. Runs the s3trash tool against a throwaway APFS disk image,
# so every trashed item lands in <vol>/.Trashes/<uid>/ inside the image and never in ~/.Trash.
#
#   bash spikes/s3-trash/run.sh
#
# Output: spikes/s3-trash/out/results.jsonl (summary.md is written by hand afterwards).
# Env: S3_SWIFTPM_FLAGS  extra flags for `swift build` (for example --disable-sandbox when
#                        the shell is already sandboxed and SwiftPM's manifest sandbox fails).
#
# Why the image mounts at /Volumes/S3Trash and not inside the repo: with `-mountpoint` set to a
# folder outside /Volumes, macOS never creates .Trashes/<uid> and every trash call (FileManager
# and NSWorkspace) fails with NSCocoaErrorDomain 513. out/results-repo-mountpoint-fails.jsonl
# keeps the evidence from that attempt.
set -euo pipefail

SPIKE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OUT="$SPIKE/out"
IMG="$OUT/s3.sparseimage"
VOLNAME="S3Trash"
VOL="/Volumes/$VOLNAME"
RESULTS="$OUT/results.jsonl"
WATCHDOG_SECONDS=1500
ATTACHED=0

is_mounted() { mount | grep -F " on $1 (" >/dev/null; }

detach_image() {
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach "$VOL" -quiet; then return 0; fi
    sleep 2
  done
  echo "detach failed, forcing" >&2
  hdiutil detach "$VOL" -force -quiet
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [ "$ATTACHED" = 1 ] && is_mounted "$VOL"; then
    # Make sure nothing in the image stays immutable or read-only.
    chflags -R nouchg "$VOL/work" "$VOL/.Trashes/$(id -u)" 2>/dev/null || true
    chmod -R u+w "$VOL/work" 2>/dev/null || true
    detach_image || echo "WARNING: image still attached at $VOL" >&2
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

cd "$SPIKE"

# 1. Build first, so a compile error never leaves an image behind.
# shellcheck disable=SC2086
if ! swift build -c release --scratch-path "$SPIKE/.build" ${S3_SWIFTPM_FLAGS:-}; then
  echo "build failed" >&2
  exit 1
fi
# shellcheck disable=SC2086
BIN="$(swift build -c release --scratch-path "$SPIKE/.build" ${S3_SWIFTPM_FLAGS:-} --show-bin-path)/s3trash"

# 2. Create and attach the image. Refuse to run if anything already uses the names.
mkdir -p "$OUT"
if [ -e "$VOL" ]; then
  echo "$VOL already exists; eject or rename it first" >&2
  exit 1
fi
if hdiutil info | grep -F "$IMG" >/dev/null; then
  echo "an image at $IMG is already attached; detach it first" >&2
  exit 1
fi
hdiutil create -ov -size 300m -type SPARSE -fs APFS -volname "$VOLNAME" -quiet "$IMG"
hdiutil attach -nobrowse -noverify -noautofsck -quiet "$IMG"
ATTACHED=1
if ! is_mounted "$VOL"; then
  echo "attach did not produce a mount at $VOL" >&2
  exit 1
fi
touch "$VOL/.metadata_never_index"
echo "mounted: $(mount | grep -F " on $VOL (")"

# 3. Run the tool against the mount point only, with a watchdog against hangs.
status=0
"$BIN" "$VOL" "$RESULTS" &
tool_pid=$!
( sleep "$WATCHDOG_SECONDS"; echo "watchdog: killing s3trash" >&2; kill "$tool_pid" 2>/dev/null ) &
watchdog_pid=$!
wait "$tool_pid" || status=$?
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true

echo "s3trash exit code: $status"
echo "results: $(wc -l < "$RESULTS" | tr -d ' ') lines in $RESULTS"
exit "$status"

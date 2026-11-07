#!/bin/bash
# Usage: run-bench.sh <root> [limit-seconds]
# Builds Release, then runs bulk/fm/fts with 1 and 8 workers plus `du -skx`,
# each under /usr/bin/time -l. Writes JSON lines to out/bench-<timestamp>.jsonl.
# Read-only on <root>. Env: WARMUP=0 skips the cache-warming pass,
# SWIFT_BUILD_FLAGS adds flags to `swift build` (e.g. --disable-sandbox).
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: run-bench.sh <root> [limit-seconds]" >&2
    exit 2
fi
root="$1"
limit="${2:-}"
if [ ! -d "$root" ] || [ -L "$root" ]; then
    echo "run-bench: $root is not a real directory" >&2
    exit 2
fi
case "$limit" in
    "" | *[!0-9.]*)
        if [ -n "$limit" ]; then
            echo "run-bench: limit-seconds must be a number" >&2
            exit 2
        fi
        ;;
esac

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/out"
mkdir -p "$out"
stamp="$(date +%Y%m%d-%H%M%S)"
jsonl="$out/bench-$stamp.jsonl"
timefile="$(mktemp "$out/time.XXXXXX")"
trap 'rm -f "$timefile"' EXIT

# shellcheck disable=SC2086
(cd "$here" && swift build -c release ${SWIFT_BUILD_FLAGS:-} >&2)
# shellcheck disable=SC2086
bin="$(cd "$here" && swift build -c release ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/s1walker"

limit_args=()
if [ -n "$limit" ]; then limit_args=(--limit-seconds "$limit"); fi

# Prints "real user sys maxRSSbytes" from a `time -l` report.
parse_time() {
    awk '
        /real/ && /user/ && /sys/ { real = $1; user = $3; sys = $5 }
        /maximum resident set size/ { rss = $1 }
        END { printf "%s %s %s %s\n", real, user, sys, rss }
    ' "$timefile"
}

json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

ncpu="$(sysctl -n hw.ncpu)"
printf '{"meta":{"date":"%s","root":"%s","limitSeconds":"%s","arch":"%s","ncpu":%s,"macOS":"%s"}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$root")" "$limit" "$(uname -m)" "$ncpu" \
    "$(sw_vers -productVersion)" >"$jsonl"

if [ "${WARMUP:-1}" = "1" ]; then
    "$bin" --method bulk --workers 8 ${limit_args[@]+"${limit_args[@]}"} "$root" >/dev/null || true
fi

for method in bulk fm fts; do
    for workers in 1 8; do
        echo "running $method workers=$workers" >&2
        result="$(/usr/bin/time -l -o "$timefile" "$bin" --method "$method" --workers "$workers" \
            ${limit_args[@]+"${limit_args[@]}"} --json "$root")"
        read -r real user sys rss <<<"$(parse_time)"
        printf '{"tool":"s1walker","time":{"real":%s,"user":%s,"sys":%s,"maxRSSBytes":%s},"result":%s}\n' \
            "$real" "$user" "$sys" "$rss" "$result" >>"$jsonl"
    done
done

echo "running du -skx" >&2
status=0
if [ -n "$limit" ]; then
    # perl's alarm ends du after the limit; the process is exec'd so time -l measures du itself.
    kb="$(/usr/bin/time -l -o "$timefile" perl -e 'alarm shift; exec @ARGV' "$limit" du -skx "$root" 2>/dev/null | cut -f1)" || status=$?
else
    kb="$(/usr/bin/time -l -o "$timefile" du -skx "$root" 2>/dev/null | cut -f1)" || status=$?
fi
read -r real user sys rss <<<"$(parse_time)"
# du exits non-zero on unreadable folders; a missing number means it was cut off by the limit.
partial=false
if [ -z "$kb" ]; then
    partial=true
    kb=null
fi
printf '{"tool":"du","time":{"real":%s,"user":%s,"sys":%s,"maxRSSBytes":%s},"result":{"kilobytes":%s,"partial":%s,"exitStatus":%s}}\n' \
    "$real" "$user" "$sys" "$rss" "$kb" "$partial" "$status" >>"$jsonl"

echo "wrote $jsonl" >&2
cat "$jsonl"

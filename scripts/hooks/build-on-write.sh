#!/usr/bin/env bash
# PostToolUse(fs_write): after a Swift write under Packages/ or src/, build CleanerKit.
# Non-zero exit is a warning the agent sees on stderr; it does not undo the write.
# shellcheck source=scripts/hooks/lib.sh
source "$(dirname "$0")/lib.sh"
event="$(cat)"
path="$(hook_field "$event" tool_input.path)"
rel="${path#"$HOOK_ROOT"/}"
case "$rel" in
  Packages/*.swift|src/*.swift) ;;
  *) exit 0 ;;
esac
[ -f "$PACKAGE_DIR/Package.swift" ] || exit 0
# --disable-sandbox: SwiftPM's manifest sandbox cannot nest inside the agent sandbox
# (EVIDENCE S8/S2/S4). It only turns off SwiftPM's own manifest/plugin sandbox.
out="$(swift build --disable-sandbox --package-path "$PACKAGE_DIR" --scratch-path "$HOOK_ROOT/build/swiftpm" 2>&1)"
status=$?
hook_log "build-on-write $rel exit=$status"
if [ $status -ne 0 ]; then
  printf 'build-on-write: CleanerKit build FAILED after writing %s. Fix before finishing.\n%s\n' \
    "$rel" "$(printf '%s' "$out" | grep -E 'error:|warning:' | head -40)" >&2
  exit 1
fi
exit 0

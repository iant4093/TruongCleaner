#!/usr/bin/env bash
# REQ-SAFE-01: deleting APIs and process launching stay inside the allowed modules.
#   check-deletion-sites.sh               scan the repo
#   check-deletion-sites.sh --self-test   run the matcher on a fixture under build/
#
# Scanned: every *.swift under src/ and Packages/CleanerKit/Sources/.
#   Deleting APIs (removeItem, trashItem, recycle, unlink, unlinkat, rmdir, C remove,
#   "rm", "/bin/rm"): allowed only in Packages/CleanerKit/Sources/CleanerActions/.
#   Process launching (Process(, executableURL): allowed only in CleanerActions/ and
#   CleanerScanner/**/ReadOnlyCommand*.swift (any subfolder, e.g. CleanerScanner/System/).
# Lines whose first non-blank characters are // are ignored (comments may name the APIs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ACTIONS_DIR="Packages/CleanerKit/Sources/CleanerActions/"
SCANNER_DIR="Packages/CleanerKit/Sources/CleanerScanner/"

DELETE_RE='(^|[^[:alnum:]_])(removeItem|trashItem|recycle|unlink|unlinkat|rmdir)\('
REMOVE_C_RE='(^|[^.[:alnum:]_])remove\(|(Darwin|Glibc)\.remove\('
RM_RE='"(/bin/|/usr/bin/)?rm"'
PROCESS_RE='(^|[^[:alnum:]_])Process\(|executableURL'
# A declaration such as `func remove(` is not a call.
DECL_RE='func[[:space:]]+(removeItem|trashItem|recycle|unlink|unlinkat|rmdir|remove)[[:space:]]*\('

# hits <file> <regex>: prints "line:text" for matches outside comments and declarations.
hits() {
  { grep -nE -e "$2" "$1" || true; } \
    | { grep -vE '^[0-9]+:[[:space:]]*//' || true; } \
    | { grep -vE "^[0-9]+:.*$DECL_RE" || true; }
}

# scan_root <root>: prints one "file:line: kind: text" per violation; returns 0 when clean.
scan_root() {
  local root="$1" file rel found=0 out kind re
  while IFS= read -r -d '' file; do
    rel="${file#"$root"/}"
    case "$rel" in "$ACTIONS_DIR"*) continue ;; esac
    for kind in delete remove rm; do
      case "$kind" in
        delete) re="$DELETE_RE" ;;
        remove) re="$REMOVE_C_RE" ;;
        rm) re="$RM_RE" ;;
      esac
      out="$(hits "$file" "$re")"
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | while IFS= read -r line; do
          printf '%s:%s: deleting API (%s)\n' "$rel" "${line%%:*}" "${line#*:}"
        done
        found=1
      fi
    done
    case "$rel" in
      "$SCANNER_DIR"ReadOnlyCommand*.swift | "$SCANNER_DIR"*/ReadOnlyCommand*.swift) continue ;;
    esac
    out="$(hits "$file" "$PROCESS_RE")"
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | while IFS= read -r line; do
        printf '%s:%s: process launch (%s)\n' "$rel" "${line%%:*}" "${line#*:}"
      done
      found=1
    fi
  done < <(find "$root/src" "$root/Packages/CleanerKit/Sources" -type f -name '*.swift' -print0 2>/dev/null | sort -z)
  return $found
}

run_scan() {
  local root="$1" output
  if output="$(scan_root "$root")"; then
    echo "PASS: no deleting API or process launch outside the allowed modules"
    return 0
  fi
  printf '%s\n' "$output"
  echo "FAIL: forbidden call sites above. Deletion belongs in CleanerActions (SafetyGate + executors);"
  echo "      process launching belongs in CleanerActions or CleanerScanner/**/ReadOnlyCommand*.swift."
  return 1
}

self_test() {
  local base="$ROOT/build/check-deletion-selftest-$$"
  case "$base" in "$ROOT"/build/*) ;; *) echo "self-test: refusing path $base" >&2; exit 2 ;; esac
  # shellcheck disable=SC2064  # expand $base now: the local is out of scope when the trap fires
  trap "rm -rf -- '$base'" EXIT
  local actions="$base/$ACTIONS_DIR" scanner="$base/$SCANNER_DIR" core="$base/Packages/CleanerKit/Sources/CleanerCore" app="$base/src/TruongCleaner"
  mkdir -p "$actions" "$scanner/System" "$core" "$app"

  # Allowed files: every token inside CleanerActions, Process in ReadOnlyCommand, comments elsewhere.
  cat > "$actions/Executor.swift" <<'SWIFT'
import Foundation
func run() throws {
    try FileManager.default.removeItem(at: URL(fileURLWithPath: "/x"))
    _ = try FileManager.default.trashItem(at: URL(fileURLWithPath: "/x"), resultingItemURL: nil)
    unlink("x"); unlinkat(0, "x", 0); rmdir("x"); remove("x")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/rm")
}
SWIFT
  cat > "$scanner/System/ReadOnlyCommand.swift" <<'SWIFT'
import Foundation
func run() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil") }
SWIFT
  cat > "$core/Clean.swift" <<'SWIFT'
// FileManager.removeItem( is mentioned here only in a comment.
/// Never call trashItem( from here.
public struct Clean { public func remove(_ x: Int) {} public var items: [Int] = []
  public mutating func drop() { items.remove(at: 0) } }
SWIFT
  if ! scan_root "$base" >/dev/null; then
    echo "self-test FAIL: clean fixture was flagged"; scan_root "$base"; exit 1
  fi

  # Forbidden files: one per kind.
  cat > "$core/BadDelete.swift" <<'SWIFT'
import Foundation
func bad() throws { try FileManager.default.removeItem(atPath: "/x") }
SWIFT
  cat > "$app/BadRecycle.swift" <<'SWIFT'
import AppKit
func bad() { NSWorkspace.shared.recycle([], completionHandler: nil) }
SWIFT
  cat > "$scanner/Walker.swift" <<'SWIFT'
import Foundation
func bad() { unlink("x"); let p = Process(); p.executableURL = nil; _ = p }
SWIFT
  cat > "$core/BadRm.swift" <<'SWIFT'
let rm = "/bin/rm"
let rm2 = "rm"
let c = remove("x")
SWIFT
  local output
  if output="$(scan_root "$base")"; then
    echo "self-test FAIL: forbidden fixtures were not flagged"; exit 1
  fi
  local expect
  for expect in "CleanerCore/BadDelete.swift:2" "src/TruongCleaner/BadRecycle.swift:2" \
                "CleanerScanner/Walker.swift:2: deleting API" "CleanerScanner/Walker.swift:2: process launch" \
                "CleanerCore/BadRm.swift:1" "CleanerCore/BadRm.swift:2" "CleanerCore/BadRm.swift:3"; do
    if ! printf '%s\n' "$output" | grep -qF -- "$expect"; then
      echo "self-test FAIL: missing expected hit '$expect'"; printf '%s\n' "$output"; exit 1
    fi
  done
  if printf '%s\n' "$output" | grep -qE 'CleanerActions/|ReadOnlyCommand|CleanerCore/Clean\.swift'; then
    echo "self-test FAIL: allowed file was flagged"; printf '%s\n' "$output"; exit 1
  fi
  echo "PASS: self-test (allowed files pass, forbidden files are reported with file:line)"
}

case "${1:-}" in
  "")          run_scan "$ROOT" ;;
  --self-test) self_test ;;
  *)           echo "Usage: scripts/check-deletion-sites.sh [--self-test]" >&2; exit 2 ;;
esac

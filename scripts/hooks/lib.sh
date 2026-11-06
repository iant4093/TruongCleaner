#!/usr/bin/env bash
# Shared helpers for .kiro/hooks command hooks. Hooks receive the event JSON on stdin.
set -uo pipefail
HOOK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK_STATE="$HOOK_ROOT/build/hooks"
export PACKAGE_DIR="$HOOK_ROOT/Packages/CleanerKit"
mkdir -p "$HOOK_STATE"

# hook_field <json> <dot.path>  -> prints the value or nothing (plutil reads JSON).
hook_field() {
  printf '%s' "$1" | /usr/bin/plutil -extract "$2" raw -o - - 2>/dev/null || true
}

hook_log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$HOOK_STATE/hooks.log"; }

# json_string <text> -> a JSON string literal (for {"decision":"block","reason":...}).
json_string() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

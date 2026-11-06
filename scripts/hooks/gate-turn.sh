#!/usr/bin/env bash
# Stop: when code changed, the turn may not end until lint, package tests, the
# deletion-site check and the Debug build pass. Prints {"decision":"block","reason":...},
# which Kiro sends back to the agent. Loop guard: at most 3 blocks per session.
# shellcheck source=scripts/hooks/lib.sh
source "$(dirname "$0")/lib.sh"
event="$(cat)"
session="$(hook_field "$event" session_id)"
cd "$HOOK_ROOT" || exit 0
if [ -z "$(git status --porcelain -- src Packages scripts TruongCleaner.xcodeproj 2>/dev/null)" ]; then exit 0; fi

counter="$HOOK_STATE/gate-${session:-unknown}.count"
count="$(cat "$counter" 2>/dev/null || echo 0)"

report=""
run_step() {
  local name="$1"; shift
  [ -f "$1" ] || return 0            # script not created yet (early Wave 1)
  local out
  if ! out="$(bash "$@" 2>&1)"; then
    report+="== $name FAILED ==\n$(printf '%s' "$out" | tail -30)\n"
  fi
}
run_step lint scripts/lint.sh
run_step deletion-sites scripts/check-deletion-sites.sh
run_step "package tests" scripts/test.sh package
if [ -d TruongCleaner.xcodeproj ]; then run_step "debug build" scripts/build.sh debug; fi

if [ -z "$report" ]; then
  rm -f "$counter"
  hook_log "gate-turn session=$session PASS"
  exit 0
fi
if [ "$count" -ge 3 ]; then
  hook_log "gate-turn session=$session FAIL (guard reached, turn allowed to end)"
  printf 'gate-turn: checks still failing after 3 retries; report this to the orchestrator.\n' >&2
  exit 0
fi
echo $((count + 1)) > "$counter"
hook_log "gate-turn session=$session BLOCK $((count + 1))/3"
printf '{"decision":"block","reason":%s}' \
  "$(json_string "$(printf 'gate-turn: fix these failures before you finish.\n%b' "$report")")"
exit 0

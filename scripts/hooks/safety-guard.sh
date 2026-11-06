#!/usr/bin/env bash
# PreToolUse(execute_bash): block commands that could clean or delete real data
# (safety.md rule 17), and block unsafe commits. Exit 2 denies with the reason on stderr.
# Also usable directly: `bash scripts/hooks/safety-guard.sh --check "<command>"`.
# shellcheck source=scripts/hooks/lib.sh
source "$(dirname "$0")/lib.sh"
if [ "${1:-}" = --check ]; then
  cmd="${2:-}"
else
  event="$(cat)"
  cmd="$(hook_field "$event" tool_input.command)"
fi
[ -n "$cmd" ] || exit 0

deny() {
  printf 'safety-guard: blocked (%s). Agents must never clean or delete real data on this Mac; use fixture trees under build/. See .kiro/steering/safety.md rule 17.\n' "$1" >&2
  hook_log "safety-guard BLOCK $1 :: ${cmd:0:200}"
  exit 2
}

# 1. Destructive cleaning commands, anywhere in a chained command.
patterns=(
  'tmutil[[:space:]]+(delete|thin)'
  'simctl[[:space:]]+(delete|erase)'
  'simctl[[:space:]]+runtime[[:space:]]+delete'
  'brew[[:space:]]+(cleanup|uninstall|autoremove)'
  'docker[^;&|]*prune'
  'mdutil[[:space:]]+-[a-zA-Z]*E'
  'go[[:space:]]+clean'
  'npm[[:space:]]+cache[[:space:]]+clean'
  'pnpm[[:space:]]+store[[:space:]]+prune'
  '(^|[;&|][[:space:]]*)trash[[:space:]]'
  '(^|[;&|[:space:]])sudo[[:space:]]'
  'osascript'
  'diskutil[[:space:]]+(erase|apfs[[:space:]]+delete|apfs[[:space:]]+purge)'
  '(^|[;&|[:space:]])purge([[:space:]]|$)'
)
for p in "${patterns[@]}"; do
  if printf '%s' "$cmd" | grep -Eq -- "$p"; then deny "matches '$p'"; fi
done

# 2. rm with a recursive flag is allowed only on build/ or spikes/*/out/ inside the repo.
if printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*[rR]'; then
  targets="$(printf '%s' "$cmd" | grep -Eo '(^|[;&|[:space:]])rm[[:space:]]+[^;&|]*' | sed -E 's/^[;&|[:space:]]*rm[[:space:]]+//')"
  for t in $targets; do
    case "$t" in
      -*) continue ;;
      build|build/*|./build|./build/*|"$HOOK_ROOT"/build|"$HOOK_ROOT"/build/*) ;;
      spikes/*/out|spikes/*/out/*|"$HOOK_ROOT"/spikes/*/out|"$HOOK_ROOT"/spikes/*/out/*) ;;
      *) deny "recursive rm outside build/ or spikes/*/out/: $t" ;;
    esac
    case "$t" in *..*) deny "recursive rm with '..': $t" ;; esac
  done
fi

# 3. Commits: .kiro must stay tracked; no obvious secrets.
case "$cmd" in
  *"git commit"*)
    cd "$HOOK_ROOT" || exit 2
    for p in .kiro .kiro/steering/safety.md .kiro/agents/builder-sonnet.json; do
      if git check-ignore -q --no-index "$p" 2>/dev/null; then deny ".gitignore ignores $p"; fi
    done
    if git diff --cached -U0 2>/dev/null | grep -Eq 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}'; then
      deny "possible secret in staged changes"
    fi
    ;;
esac
exit 0

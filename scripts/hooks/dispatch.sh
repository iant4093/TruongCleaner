#!/usr/bin/env bash
# Orchestrator helper: dispatch briefs to builder-sonnet in parallel.
#
#   bash scripts/hooks/dispatch.sh 0.2 0.3        # run in this checkout
#   bash scripts/hooks/dispatch.sh -w 2.1 2.2     # one git worktree per brief
#
# Worktree mode creates build/worktrees/<id> on branch wt/<id> from HEAD, so
# parallel builders never see each other's half-written files. The
# orchestrator reviews and commits inside the worktree, then merges the branch.
# Logs: build/dispatch/<id>.log ; marker build/dispatch/<id>.done holds the exit code.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
mkdir -p build/dispatch build/worktrees
worktree=0
if [ "${1:-}" = -w ]; then worktree=1; shift; fi
for id in "$@"; do
  brief="$ROOT/docs/briefs/$id.md"
  [ -f "$brief" ] || { echo "missing $brief" >&2; exit 2; }
  dir="$ROOT"
  extra=()
  if [ $worktree -eq 1 ]; then
    dir="$ROOT/build/worktrees/$id"
    if [ ! -d "$dir" ]; then
      git worktree add -q -b "wt/$id" "$dir" HEAD || { echo "worktree failed for $id" >&2; exit 2; }
    fi
    extra=(--trust-workspace)
  fi
  rm -f "build/dispatch/$id.done"
  (
    cd "$dir" || exit 1
    kiro-cli chat --v3 --agent builder-sonnet --no-interactive "${extra[@]}" \
      --trust-tools=fs_read,fs_write,shell,execute_bash,grep,glob \
      "$(cat "$brief")" > "$ROOT/build/dispatch/$id.log" 2>&1
    echo $? > "$ROOT/build/dispatch/$id.done"
  ) &
  echo "dispatched $id in $dir (pid $!)"
done

#!/usr/bin/env bash
# PreToolUse(fs_write): enforce file ownership by exact repo-relative path.
# Agent-profile globs such as "README.md" match nested files too, so root-only
# files are checked here instead. Exit 2 denies with the reason on stderr.
# Applies to every kiro-cli agent in this workspace; the orchestrator edits its
# own files from Kiro Crew, where these hooks do not run.
# shellcheck source=scripts/hooks/lib.sh
source "$(dirname "$0")/lib.sh"
event="$(cat)"
printf '%s' "$event" > "$HOOK_STATE/last-fs-write-event.json"
path="$(hook_field "$event" tool_input.path)"
[ -n "$path" ] || exit 0
case "$path" in
  /*) abs="$path" ;;
  *) abs="$HOOK_ROOT/$path" ;;
esac
rel="${abs#"$HOOK_ROOT"/}"

deny() {
  printf 'ownership-guard: %s is owned by the orchestrator (%s). Say in your report what change you need.\n' "$rel" "$1" >&2
  hook_log "ownership-guard BLOCK $rel ($1)"
  exit 2
}

if [ "$rel" = "$abs" ]; then deny "outside the repo"; fi
case "$rel" in
  *..*) deny "path contains '..'" ;;
  README.md|AGENTS.md|LICENSE|.gitignore|.swiftlint.yml) deny "root file" ;;
  .kiro/*|.github/*|scripts/hooks/*) deny "orchestrator folder" ;;
  docs/screenshots/*) exit 0 ;;
  docs/*) deny "docs" ;;
  src/*|Packages/*|TruongCleaner.xcodeproj/*|scripts/*|spikes/*|build/*) exit 0 ;;
  *) deny "not in the builder's folders" ;;
esac

#!/usr/bin/env bash
# Removes build/ and dist/ inside this repo, and nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

for name in build dist; do
  target="$ROOT/$name"
  [ -e "$target" ] || [ -L "$target" ] || continue
  if [ -L "$target" ]; then
    echo "clean: $target is a symlink; refusing to remove it" >&2
    exit 1
  fi
  resolved="$(cd "$target" && pwd -P)"
  if [ "$resolved" != "$ROOT/$name" ]; then
    echo "clean: $target resolves outside the repo ($resolved); refusing" >&2
    exit 1
  fi
  rm -rf -- "$resolved"
  echo "removed $name/"
done

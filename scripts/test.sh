#!/usr/bin/env bash
# CleanerKit tests (Swift Testing).
#   test.sh [package]   run all package tests; fails on test failures, errors or warnings
#   test.sh list        list the tests
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode="${1:-package}"
mkdir -p build/logs

# --disable-sandbox turns off only SwiftPM's own manifest/plugin sandbox. It is required
# inside the agent sandbox, where sandboxes cannot nest, and harmless elsewhere.
swift_args=(--disable-sandbox --package-path Packages/CleanerKit --scratch-path build/swiftpm)

case "$mode" in
  package)
    log=build/logs/test-package.log
    status=0
    swift test "${swift_args[@]}" --parallel 2>&1 | tee "$log" || status=$?
    if [ "$status" -ne 0 ]; then
      echo "FAIL: swift test exited with status $status (log: $log)" >&2
      exit "$status"
    fi
    # Match diagnostics and failure markers only. Test output echoes argument values, which
    # may contain the word "error:", so a bare substring match would give false failures.
    error_re='^error:|\.swift:[0-9]+:[0-9]+: error:|^[[:space:]]*✘|Test run with [0-9]+ tests? .*failed'
    warning_re='^warning:|\.swift:[0-9]+:[0-9]+: warning:'
    if grep -Eq "$error_re" "$log"; then
      echo "FAIL: errors or failed tests in $log" >&2
      grep -E "$error_re" "$log" | sort -u | head -40 >&2
      exit 1
    fi
    if grep -Eq "$warning_re" "$log"; then
      echo "FAIL: warnings in $log" >&2
      grep -E "$warning_re" "$log" | sort -u | head -40 >&2
      exit 1
    fi
    if ! grep -Eq 'Test run with [0-9]+ tests?|Executed [0-9]+ tests?' "$log"; then
      echo "FAIL: no test summary in $log; tests may not have run" >&2
      exit 1
    fi
    echo "PASS: package tests"
    ;;
  list)
    swift test list "${swift_args[@]}"
    ;;
  *)
    echo "Usage: scripts/test.sh [package|list]" >&2
    exit 2
    ;;
esac

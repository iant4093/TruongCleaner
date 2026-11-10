#!/usr/bin/env bash
# CleanerKit tests (Swift Testing).
#   test.sh [package]   run all package tests; fails on test failures, errors or warnings
#   test.sh list        list the tests
# The whole run is limited to TC_TEST_TIMEOUT seconds (default 900). On a hang the script samples
# the test processes into build/logs/test-hang-<timestamp>.txt, kills them, prints TIMEOUT and
# exits 124.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

mode="${1:-package}"
mkdir -p build/logs

# --disable-sandbox turns off only SwiftPM's own manifest/plugin sandbox. It is required
# inside the agent sandbox, where sandboxes cannot nest, and harmless elsewhere.
swift_args=(--disable-sandbox --package-path Packages/CleanerKit --scratch-path build/swiftpm)

# Process IDs of everything below $1, deepest last.
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null || true); do
    echo "$child"
    descendants "$child"
  done
}

# Runs the command in the background and waits at most $timeout seconds. Returns its exit status,
# or 124 after sampling and killing it when the time is up.
run_limited() {
  local timeout="$1"
  shift
  "$@" &
  local runner=$!
  while kill -0 "$runner" 2>/dev/null; do
    if [ "$SECONDS" -ge "$timeout" ]; then
      echo "TIMEOUT: tests still running after ${timeout}s" >&2
      local stamp hang pid name
      stamp=$(date +%Y%m%d-%H%M%S)
      hang="build/logs/test-hang-$stamp.txt"
      : > "$hang"
      for pid in $(descendants "$runner"); do
        name=$(ps -o comm= -p "$pid" 2>/dev/null || true)
        case "$name" in
          ""|*xctest*|*testing-helper*|*PackageTests*)
            echo "=== sample of $pid ($name) ===" >> "$hang"
            sample "$pid" 3 >> "$hang" 2>&1 || echo "sample failed for $pid" >> "$hang"
            ;;
        esac
      done
      echo "Hang report: $hang" >&2
      for pid in $(descendants "$runner"); do kill -TERM "$pid" 2>/dev/null || true; done
      kill -TERM "$runner" 2>/dev/null || true
      sleep 2
      for pid in $(descendants "$runner"); do kill -KILL "$pid" 2>/dev/null || true; done
      kill -KILL "$runner" 2>/dev/null || true
      wait "$runner" 2>/dev/null || true
      return 124
    fi
    sleep 1
  done
  wait "$runner"
}

timeout_seconds="${TC_TEST_TIMEOUT:-900}"
case "$timeout_seconds" in
  ''|*[!0-9]*) echo "TC_TEST_TIMEOUT must be a number of seconds, got '$timeout_seconds'" >&2; exit 2 ;;
esac

# Runs `swift test` for the package and copies its output to the log.
swift_test_logged() {
  set -o pipefail
  swift test "${swift_args[@]}" "$@" 2>&1 | tee "$log"
}

case "$mode" in
  package)
    log=build/logs/test-package.log
    status=0
    SECONDS=0
    # TC_TEST_PARALLEL=0 runs test cases serially (3-core CI runners: timing tests compete otherwise).
    if [ "${TC_TEST_PARALLEL:-1}" = 0 ]; then par=(--no-parallel); else par=(--parallel); fi
    run_limited "$timeout_seconds" swift_test_logged "${par[@]}" || status=$?
    if [ "$status" -eq 124 ]; then
      echo "FAIL: TIMEOUT after ${timeout_seconds}s (log: $log)" >&2
      exit 124
    fi
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

#!/usr/bin/env bash
# Unsigned Debug/Release builds of TruongCleaner.app.
#   build.sh [debug|release|all]        (default: all)
# Environment:
#   TRUONGCLEANER_BUILD_NUMBER  digits only; becomes CURRENT_PROJECT_VERSION
#   TC_XCODEBUILD_FLAGS         extra xcodebuild arguments, split on spaces (default: none).
#                               Inside the agent sandbox use OTHER_SWIFT_FLAGS=-disable-sandbox.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PROJECT="TruongCleaner.xcodeproj"
SCHEME="TruongCleaner"
LOG_DIR="$ROOT/build/logs"
mkdir -p "$LOG_DIR"

mode="${1:-all}"

extra_flags=()
if [ -n "${TC_XCODEBUILD_FLAGS:-}" ]; then
  read -r -a extra_flags <<< "$TC_XCODEBUILD_FLAGS"
fi

print_toolchain() {
  echo "== toolchain =="
  xcodebuild -version
  echo "xcode-select: $(xcode-select -p)"
  echo "macosx SDK: $(xcrun --sdk macosx --show-sdk-path)"
  echo "macosx SDK version: $(xcrun --sdk macosx --show-sdk-version)"
  swift --version 2>&1 | head -2
  echo
}

build_config() {
  local config="$1"
  local derived="$ROOT/build/${config}DerivedData"
  local log="$LOG_DIR/build-${config}.log"
  echo "== macOS build ($config) =="
  echo "log: $log"

  local overrides=()
  if [ -n "${TRUONGCLEANER_BUILD_NUMBER:-}" ]; then
    case "$TRUONGCLEANER_BUILD_NUMBER" in
      *[!0-9]*) echo "Invalid TRUONGCLEANER_BUILD_NUMBER (digits only)" >&2; return 2 ;;
    esac
    overrides+=("CURRENT_PROJECT_VERSION=$TRUONGCLEANER_BUILD_NUMBER")
  fi

  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$config" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    ${overrides[@]+"${overrides[@]}"} \
    ${extra_flags[@]+"${extra_flags[@]}"} \
    build >"$log" 2>&1
  local status=$?

  if [ $status -ne 0 ]; then
    echo "FAIL: $config build (exit $status)"
    grep -E "error:" "$log" | sort -u | head -40
    return $status
  fi

  # Source warnings only. Tool notices such as appintentsmetadataprocessor are not code.
  local warnings
  warnings="$(grep -E '\.swift:[0-9]+:[0-9]+: warning:' "$log" | sort -u)"
  if [ -n "$warnings" ]; then
    echo "FAIL: $config build has Swift source warnings (warnings are errors here)"
    printf '%s\n' "$warnings" | head -40
    return 1
  fi

  echo "PASS: $config build (exit 0)"
  local app="$derived/Build/Products/${config}/TruongCleaner.app"
  if [ -d "$app" ]; then
    echo "app: $app"
    /usr/bin/du -sh "$app" | /usr/bin/awk '{print "size: " $1}'
  else
    echo "FAIL: expected app not found at $app"
    return 1
  fi
  return 0
}

print_toolchain

overall=0
case "$mode" in
  debug)   build_config Debug || overall=1 ;;
  release) build_config Release || overall=1 ;;
  all)
    build_config Debug || overall=1
    echo
    build_config Release || overall=1
    ;;
  *)
    echo "Usage: scripts/build.sh [debug|release|all]" >&2
    exit 2
    ;;
esac

echo
if [ $overall -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
fi
exit $overall

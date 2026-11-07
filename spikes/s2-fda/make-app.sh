#!/usr/bin/env bash
# Builds S2FDA in Release and wraps it into out/S2FDA.app (ad-hoc signed).
# Writes only inside spikes/s2-fda/ (.build/ and out/).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
OUT="$ROOT/out"
APP="$OUT/S2FDA.app"
BUNDLE_ID="com.iant4093.TruongCleaner.spike.s2"
# Extra SwiftPM flags, e.g. SPIKE_SWIFT_FLAGS=--disable-sandbox when run inside another sandbox.
read -r -a EXTRA_FLAGS <<< "${SPIKE_SWIFT_FLAGS:-}"

mkdir -p "$OUT"
LOG="$OUT/build.log"
echo "==> swift build -c release"
swift build -c release --arch arm64 ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} 2>&1 | tee "$LOG"
if grep -q "warning:" "$LOG"; then
    echo "error: build produced warnings" >&2
    exit 1
fi

BIN_DIR="$(swift build -c release --arch arm64 ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/S2FDA"
[[ -x "$BIN" ]] || { echo "error: missing $BIN" >&2; exit 1; }

echo "==> wrapping $APP"
mkdir -p "$OUT"
# Only ever remove the app bundle inside this spike's out/ folder.
if [[ -d "$APP" && "$APP" == "$ROOT/out/S2FDA.app" ]]; then
    rm -rf "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/S2FDA"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>S2FDA</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>S2FDA</string>
    <key>CFBundleDisplayName</key><string>S2FDA</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> done: $APP"

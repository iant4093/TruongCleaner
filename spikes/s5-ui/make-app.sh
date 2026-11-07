#!/bin/bash
# Spike S5: build Release and wrap the binary into out/S5UI.app, ad-hoc signed.
# Writes only inside spikes/s5-ui/ (.build/ and out/). Deletes nothing.
set -euo pipefail

cd "$(dirname "$0")"

# Set S5_NO_SANDBOX=1 only where SwiftPM's own sandbox-exec cannot nest
# (for example inside another sandbox, such as an agent runner).
extra=()
if [ "${S5_NO_SANDBOX:-0}" = "1" ]; then
    extra+=(--disable-sandbox)
fi

swift build -c release --arch arm64 ${extra[@]+"${extra[@]}"}
bin_dir="$(swift build -c release --arch arm64 --show-bin-path ${extra[@]+"${extra[@]}"})"

app="out/S5UI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -f "$bin_dir/S5UI" "$app/Contents/MacOS/S5UI"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.iant4093.TruongCleaner.spike.s5</string>
    <key>CFBundleName</key>
    <string>S5UI</string>
    <key>CFBundleDisplayName</key>
    <string>S5UI</string>
    <key>CFBundleExecutable</key>
    <string>S5UI</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
codesign --verify --strict --verbose=2 "$app"
echo "Built $app"

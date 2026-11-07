#!/usr/bin/env bash
# Ad-hoc sign the Release app, verify it, and build the release artifacts in dist/:
#   TruongCleaner.zip, TruongCleaner.dmg, TruongCleaner.dSYM.zip, install.sh, SHA256SUMS
# Run scripts/build.sh release first.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

APP_NAME="TruongCleaner"
SRC_APP="$ROOT/build/ReleaseDerivedData/Build/Products/Release/$APP_NAME.app"
SRC_DSYM="$SRC_APP.dSYM"
PKG_DIR="$ROOT/build/package"
APP="$PKG_DIR/$APP_NAME.app"
DSYM="$PKG_DIR/$APP_NAME.app.dSYM"
DIST="$ROOT/dist"
LOG_DIR="$ROOT/build/logs"
mkdir -p "$LOG_DIR"

die() { echo "FAIL: $*" >&2; exit 1; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
size() { /usr/bin/du -h "$1" | /usr/bin/awk '{print $1}'; }

[ -d "$SRC_APP" ] || die "Release app not found at $SRC_APP (run scripts/build.sh release first)"
[ -d "$SRC_DSYM" ] || die "Release dSYM not found at $SRC_DSYM"

PLIST="$SRC_APP/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
EXEC_NAME="$(read_plist CFBundleExecutable)"
[ -n "$EXEC_NAME" ] || die "CFBundleExecutable missing in $PLIST"
VERSION="$(read_plist CFBundleShortVersionString)"
BUILD="$(read_plist CFBundleVersion)"
BUNDLE_ID="$(read_plist CFBundleIdentifier)"

echo "== stage =="
# build/package is ours (inside build/); rebuild it from scratch each time.
case "$PKG_DIR" in "$ROOT"/build/*) ;; *) die "unexpected package dir $PKG_DIR" ;; esac
/bin/rm -rf -- "$PKG_DIR"
/bin/mkdir -p "$PKG_DIR"
/usr/bin/ditto "$SRC_APP" "$APP" || die "could not copy the app"
/usr/bin/ditto "$SRC_DSYM" "$DSYM" || die "could not copy the dSYM"

echo "== ad-hoc sign (inside-out) =="
# Nested code first, deepest first; the app bundle last. No --deep.
nested="$(
  /usr/bin/find "$APP/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' \
    -o -name '*.app' -o -name '*.dylib' -o -name '*.bundle' \) -print 2>/dev/null \
    | /usr/bin/awk -F/ '{print NF "\t" $0}' | /usr/bin/sort -rn | /usr/bin/cut -f2-
)"
if [ -n "$nested" ]; then
  while IFS= read -r item; do
    echo "sign: ${item#"$APP"/}"
    /usr/bin/codesign --force --sign - --timestamp=none "$item" || die "codesign failed for $item"
  done <<< "$nested"
else
  echo "(no nested code)"
fi
/usr/bin/codesign --force --sign - --timestamp=none "$APP" || die "codesign failed for the app"

echo "== verify =="
BINARY="$APP/Contents/MacOS/$EXEC_NAME"
[ -f "$BINARY" ] || die "executable not found at $BINARY"

/usr/bin/codesign --verify --strict --verbose=2 "$APP" || die "codesign --verify failed"

ARCHS="$(/usr/bin/lipo -archs "$BINARY" 2>/dev/null)"
[ "$ARCHS" = "arm64" ] || die "architectures are '$ARCHS', expected exactly 'arm64'"
echo "architectures: $ARCHS"

BUILD_INFO="$(/usr/bin/xcrun vtool -show-build "$BINARY" 2>/dev/null)"
platform="$(printf '%s\n' "$BUILD_INFO" | /usr/bin/awk '$1=="platform"{print $2; exit}')"
minos="$(printf '%s\n' "$BUILD_INFO" | /usr/bin/awk '$1=="minos"{print $2; exit}')"
sdk="$(printf '%s\n' "$BUILD_INFO" | /usr/bin/awk '$1=="sdk"{print $2; exit}')"
[ "$platform" = "MACOS" ] || die "platform is '$platform', expected MACOS"
[ "$minos" = "26.0" ] || die "minos is '$minos', expected 26.0"
echo "platform: $platform  minos: $minos  sdk: $sdk"

bad_libs="$(/usr/bin/otool -L "$BINARY" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' \
  | /usr/bin/grep -vE '^(/System/|/usr/lib/)' || true)"
[ -z "$bad_libs" ] || die "non-system libraries linked: $bad_libs"
echo "linked libraries: system only"

if [ -d "$APP/Contents/Frameworks" ] && [ -n "$(/bin/ls -A "$APP/Contents/Frameworks")" ]; then
  die "Contents/Frameworks is not empty: $(/bin/ls "$APP/Contents/Frameworks" | /usr/bin/tr '\n' ' ')"
fi
echo "embedded frameworks: none"

BINARY_UUID="$(/usr/bin/xcrun dwarfdump --uuid "$BINARY" 2>/dev/null | /usr/bin/awk '/^UUID:/ {print $2}' | /usr/bin/sort)"
DSYM_UUID="$(/usr/bin/xcrun dwarfdump --uuid "$DSYM" 2>/dev/null | /usr/bin/awk '/^UUID:/ {print $2}' | /usr/bin/sort)"
if [ -z "$BINARY_UUID" ] || [ "$BINARY_UUID" != "$DSYM_UUID" ]; then
  die "dSYM UUID ($DSYM_UUID) does not match the binary ($BINARY_UUID)"
fi
echo "binary UUID: $BINARY_UUID (matches dSYM)"

echo "== dist =="
case "$DIST" in "$ROOT"/dist) ;; *) die "unexpected dist dir $DIST" ;; esac
/bin/rm -rf -- "$DIST"
/bin/mkdir -p "$DIST"

/usr/bin/ditto -c -k --keepParent "$APP" "$DIST/$APP_NAME.zip" || die "zip failed"

STAGE="$PKG_DIR/dmg-stage"
/bin/mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/$APP_NAME.app" || die "could not stage the app for the DMG"
/bin/ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -ov \
  "$DIST/$APP_NAME.dmg" >"$LOG_DIR/package-hdiutil.log" 2>&1 \
  || { /usr/bin/tail -20 "$LOG_DIR/package-hdiutil.log"; die "hdiutil create failed"; }

/usr/bin/ditto -c -k --keepParent "$DSYM" "$DIST/$APP_NAME.dSYM.zip" || die "dSYM zip failed"
/bin/cp "$ROOT/scripts/install.sh" "$DIST/install.sh" || die "could not copy install.sh"

# Order: ZIP, DMG, dSYM ZIP, install.sh. install.sh reads the ZIP line by file name.
(
  cd "$DIST" || exit 1
  /usr/bin/shasum -a 256 "$APP_NAME.zip" "$APP_NAME.dmg" "$APP_NAME.dSYM.zip" install.sh > SHA256SUMS
) || die "could not write SHA256SUMS"
(cd "$DIST" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not verify"

echo
for f in "$APP_NAME.zip" "$APP_NAME.dmg" "$APP_NAME.dSYM.zip" install.sh SHA256SUMS; do
  printf '%-24s %8s  %s\n' "$f" "$(size "$DIST/$f")" "$([ "$f" = SHA256SUMS ] || sha "$DIST/$f")"
done
echo
/bin/cat "$DIST/SHA256SUMS"

/bin/cat > "$PKG_DIR/PACKAGING.txt" <<TXT
TruongCleaner release candidate
===============================
version:        $VERSION ($BUILD)
bundle id:      $BUNDLE_ID
architectures:  $ARCHS
platform:       $platform, minos $minos, sdk $sdk
signature:      ad-hoc (codesign --sign -), not notarized, Hardened Runtime off
linked libs:    /System and /usr/lib only; no embedded frameworks
binary UUID:    $(printf '%s' "$BINARY_UUID" | /usr/bin/tr '\n' ' ')(matches dSYM)
app size:       $(size "$APP")
created:        $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)

dist/ files (sha256):
$(cd "$DIST" && /bin/cat SHA256SUMS)

Install: curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh
DMG users: open the app once, then System Settings > Privacy & Security > Open Anyway.
TXT

echo
echo "notes: $PKG_DIR/PACKAGING.txt"
echo "RESULT: PASS"

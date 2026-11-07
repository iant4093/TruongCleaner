#!/bin/sh
# TruongCleaner installer.
#   curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh
#
# Downloads TruongCleaner.zip and SHA256SUMS from the same release, checks the ZIP against
# its line in SHA256SUMS, and installs the app. Never uses sudo.
#
# Environment (for testing):
#   TC_RELEASE_BASE  download base URL (default: latest GitHub release)
#   TC_INSTALL_DIR   install folder (default: /Applications if writable, else ~/Applications)
#   TC_NO_OPEN=1     do not open the app afterwards
#
# The only paths this script removes are its own temp folder and, after checking its
# bundle identifier, <install dir>/TruongCleaner.app.
set -eu

APP_NAME="TruongCleaner"
BUNDLE_ID="com.iant4093.TruongCleaner"
BASE="${TC_RELEASE_BASE:-https://github.com/iant4093/TruongCleaner/releases/latest/download}"

say() { printf '%s\n' "$*"; }
fail() { printf 'TruongCleaner install: %s\n' "$*" >&2; exit 1; }

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# --- Requirements -----------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || fail "this installer is for macOS only."

arm64_ok=0
if [ "$(uname -m)" = "arm64" ]; then
  arm64_ok=1
elif [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  arm64_ok=1   # a shell running under Rosetta on an Apple Silicon Mac
fi
[ "$arm64_ok" = "1" ] || fail "TruongCleaner needs a Mac with Apple Silicon (arm64)."

macos_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || echo 0)"
macos_major="${macos_version%%.*}"
case "$macos_major" in
  ''|*[!0-9]*) fail "could not read the macOS version ('$macos_version')." ;;
esac
[ "$macos_major" -ge 26 ] || fail "TruongCleaner needs macOS 26 or later (this Mac has $macos_version)."

# --- Temp folder ------------------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/truongcleaner-install.XXXXXX")" || fail "could not create a temp folder."
case "$TMP_DIR" in
  */truongcleaner-install.*) ;;
  *) fail "unexpected temp folder '$TMP_DIR'." ;;
esac
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# --- Download and verify ----------------------------------------------------------------
say "Downloading $APP_NAME from $BASE"
curl -fsSL "$BASE/$APP_NAME.zip" -o "$TMP_DIR/$APP_NAME.zip" || fail "could not download $APP_NAME.zip."
curl -fsSL "$BASE/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS" || fail "could not download SHA256SUMS."

# Keep only the ZIP's line; exactly one must exist.
awk -v name="$APP_NAME.zip" '$2 == name || $2 == "*" name' "$TMP_DIR/SHA256SUMS" > "$TMP_DIR/zip.sum"
[ "$(wc -l < "$TMP_DIR/zip.sum" | tr -d ' ')" = "1" ] || fail "SHA256SUMS has no single entry for $APP_NAME.zip."
if ! (cd "$TMP_DIR" && shasum -a 256 -c zip.sum >/dev/null 2>&1); then
  fail "checksum mismatch for $APP_NAME.zip. Nothing was installed."
fi
say "Checksum OK."

mkdir "$TMP_DIR/extract"
ditto -x -k "$TMP_DIR/$APP_NAME.zip" "$TMP_DIR/extract" || fail "could not unpack $APP_NAME.zip."
NEW_APP="$TMP_DIR/extract/$APP_NAME.app"
[ -d "$NEW_APP" ] || fail "the download does not contain $APP_NAME.app."
[ "$(bundle_id_of "$NEW_APP")" = "$BUNDLE_ID" ] || fail "the download is not $BUNDLE_ID."

# --- Choose the install folder ----------------------------------------------------------
if [ -n "${TC_INSTALL_DIR:-}" ]; then
  INSTALL_DIR="$TC_INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" || fail "could not create $INSTALL_DIR."
elif [ -w /Applications ]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR" || fail "could not create $INSTALL_DIR."
fi
[ -w "$INSTALL_DIR" ] || fail "$INSTALL_DIR is not writable."
DEST="$INSTALL_DIR/$APP_NAME.app"

# --- Quit a running copy ----------------------------------------------------------------
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  say "Asking $APP_NAME to quit..."
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  waited=0
  while pgrep -x "$APP_NAME" >/dev/null 2>&1 && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    fail "$APP_NAME is still running. Quit it and run the installer again."
  fi
fi

# --- Replace: old bundle goes to the temp folder first, so a failure leaves something ----
OLD_MOVED=0
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  [ ! -L "$DEST" ] || fail "$DEST is a symlink; remove it yourself and run the installer again."
  [ "$(bundle_id_of "$DEST")" = "$BUNDLE_ID" ] || fail "$DEST is not $APP_NAME ($BUNDLE_ID); leaving it alone."
  mkdir "$TMP_DIR/old"
  mv "$DEST" "$TMP_DIR/old/$APP_NAME.app" || fail "could not move the old $APP_NAME.app aside. Nothing was changed."
  OLD_MOVED=1
fi

restore_old() {
  if [ "$OLD_MOVED" = "1" ] && [ -d "$TMP_DIR/old/$APP_NAME.app" ]; then
    mv "$TMP_DIR/old/$APP_NAME.app" "$DEST" || true
  fi
}

if ! mv "$NEW_APP" "$DEST"; then
  # DEST did not exist before this mv (a previous copy was moved aside above), so anything
  # there now is a partial copy of the new app that this script created.
  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    rm -rf -- "$DEST"
  fi
  restore_old
  fail "could not move the new app into $INSTALL_DIR. The old version was put back."
fi

if ! codesign --verify --strict "$DEST" >/dev/null 2>&1; then
  # Remove only the bundle we just installed, then put the old one back.
  if [ "$(bundle_id_of "$DEST")" != "$BUNDLE_ID" ]; then
    fail "the installed app failed its code signature check, and $DEST could not be identified; leaving it in place."
  fi
  rm -rf -- "$DEST"
  restore_old
  fail "the installed app failed its code signature check. The old version (if any) was put back."
fi

say "Installed $DEST"

if [ "${TC_NO_OPEN:-0}" != "1" ]; then
  open "$DEST" || say "Could not open the app. Open it from $INSTALL_DIR."
fi

say "To uninstall: quit $APP_NAME and move $DEST to the Trash."

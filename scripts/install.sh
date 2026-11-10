#!/bin/sh
# TruongCleaner installer.
#   curl -fsSL https://github.com/iant4093/TruongCleaner/releases/latest/download/install.sh | sh
#
# Downloads TruongCleaner.zip and SHA256SUMS from the same release, checks the ZIP against
# its line in SHA256SUMS, and installs the app. Never uses sudo.
#
# Environment (for testing):
#   TC_RELEASE_BASE  download base URL (default: latest GitHub release). A file:// URL is
#                    accepted only through this variable; every other download is https only.
#   TC_INSTALL_DIR   install folder (default: /Applications if writable, else ~/Applications)
#   TC_NO_OPEN=1     do not open the app afterwards
#
# An existing copy is renamed to <install dir>/.TruongCleaner.app.old (a rename inside the same
# folder), the new one is put in its place, and the old one is deleted only after the new one
# passed its signature check. If anything stops the script in between, an EXIT trap puts the old
# copy back.
#
# The only paths this script removes are its own temp folder, a partly installed new copy of
# <install dir>/TruongCleaner.app, and, after checking its bundle identifier, the old copy it
# renamed aside.
#
# Everything that runs is inside main(), called on the last line. If the download is cut off
# (curl | sh), the shell reaches the end of input inside main() and runs nothing.
set -eu

APP_NAME="TruongCleaner"
BUNDLE_ID="com.iant4093.TruongCleaner"
BASE="${TC_RELEASE_BASE:-https://github.com/iant4093/TruongCleaner/releases/latest/download}"

# State for the EXIT trap. Set by main().
TMP_DIR=""
DEST=""
OLD_APP=""
OLD_MOVED=0
NEW_PLACED=0

say() { printf '%s\n' "$*"; }
fail() { printf 'TruongCleaner install: %s\n' "$*" >&2; exit 1; }

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# fetch <url> <file>: https only, including after redirects. A file:// URL is for tests and is
# accepted only when TC_RELEASE_BASE was set.
fetch() {
  case "$1" in
    file://*)
      [ -n "${TC_RELEASE_BASE:-}" ] || return 1
      curl --proto '=file' -fsSL "$1" -o "$2"
      ;;
    https://*)
      curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL "$1" -o "$2"
      ;;
    *)
      return 1
      ;;
  esac
}

# Runs on every exit. Undoes a half-finished swap, then removes the temp folder.
cleanup() {
  if [ "$NEW_PLACED" = "1" ] && [ -n "$DEST" ] && [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    # DEST did not exist when the new app was moved in, so it is the new app or a partial copy of
    # it. Leave it alone only if it is clearly some other app.
    placed_id="$(bundle_id_of "$DEST")"
    if [ -z "$placed_id" ] || [ "$placed_id" = "$BUNDLE_ID" ]; then
      rm -rf -- "$DEST" || true
    fi
  fi
  if [ "$OLD_MOVED" = "1" ] && [ -n "$DEST" ] && [ ! -e "$DEST" ] && [ ! -L "$DEST" ] && [ -d "$OLD_APP" ]; then
    if mv "$OLD_APP" "$DEST"; then
      say "The previous $APP_NAME was put back at $DEST."
    else
      say "Could not put the previous $APP_NAME back. It is at $OLD_APP." >&2
    fi
  fi
  if [ -n "$TMP_DIR" ]; then
    rm -rf -- "$TMP_DIR" || true
  fi
}

main() {
  # --- Requirements ---------------------------------------------------------------------
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

  # --- Temp folder and exit handling ----------------------------------------------------
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/truongcleaner-install.XXXXXX")" || fail "could not create a temp folder."
  case "$TMP_DIR" in
    */truongcleaner-install.*) ;;
    *)
      bad_dir="$TMP_DIR"
      TMP_DIR=""
      fail "unexpected temp folder '$bad_dir'."
      ;;
  esac

  # --- Download and verify --------------------------------------------------------------
  say "Downloading $APP_NAME from $BASE"
  fetch "$BASE/$APP_NAME.zip" "$TMP_DIR/$APP_NAME.zip" || fail "could not download $APP_NAME.zip."
  fetch "$BASE/SHA256SUMS" "$TMP_DIR/SHA256SUMS" || fail "could not download SHA256SUMS."

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

  # --- Choose the install folder --------------------------------------------------------
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
  OLD_APP="$INSTALL_DIR/.$APP_NAME.app.old"

  # --- Check what is there before touching anything -------------------------------------
  if [ -e "$OLD_APP" ] || [ -L "$OLD_APP" ]; then
    fail "$OLD_APP is left from an earlier install. Check it, move it away and run the installer again."
  fi
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    [ ! -L "$DEST" ] || fail "$DEST is a symlink; remove it yourself and run the installer again."
    [ "$(bundle_id_of "$DEST")" = "$BUNDLE_ID" ] || fail "$DEST is not $APP_NAME ($BUNDLE_ID); leaving it alone."
  fi

  # --- Quit a running copy --------------------------------------------------------------
  # Ask politely by bundle ID, so the app can finish or refuse. Only this user's processes are
  # looked at, and none is ever killed.
  uid="$(id -u)"
  if pgrep -U "$uid" -x "$APP_NAME" >/dev/null 2>&1; then
    say "Asking $APP_NAME to quit..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    waited=0
    while pgrep -U "$uid" -x "$APP_NAME" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    if pgrep -U "$uid" -x "$APP_NAME" >/dev/null 2>&1; then
      fail "$APP_NAME is still running (it may be in the middle of a clean). Quit it and run the installer again."
    fi
  fi

  # --- Replace --------------------------------------------------------------------------
  # The old copy is renamed inside the install folder, so putting it back is a rename on the
  # same volume. The EXIT trap does that if anything below fails or the script is stopped.
  if [ -e "$DEST" ]; then
    mv "$DEST" "$OLD_APP" || fail "could not move the old $APP_NAME.app aside. Nothing was changed."
    OLD_MOVED=1
  fi

  [ ! -e "$DEST" ] && [ ! -L "$DEST" ] || fail "something appeared at $DEST while installing. Your previous version is at $OLD_APP."

  # From here DEST is ours: the new app, or a partial copy if the move is cut short.
  NEW_PLACED=1
  mv "$NEW_APP" "$DEST" || fail "could not move the new app into $INSTALL_DIR. The old version was put back."

  if ! codesign --verify --strict "$DEST" >/dev/null 2>&1; then
    fail "the installed app failed its code signature check. The old version (if any) was put back."
  fi

  # Committed: the new app is in place and verified.
  NEW_PLACED=0
  OLD_MOVED=0
  if [ -d "$OLD_APP" ] && [ ! -L "$OLD_APP" ] && [ "$(bundle_id_of "$OLD_APP")" = "$BUNDLE_ID" ]; then
    rm -rf -- "$OLD_APP" || say "Could not remove the previous version at $OLD_APP. You can move it to the Trash."
  fi

  say "Installed $DEST"

  if [ "${TC_NO_OPEN:-0}" != "1" ]; then
    open "$DEST" || say "Could not open the app. Open it from $INSTALL_DIR."
  fi

  say "To uninstall: quit $APP_NAME and move $DEST to the Trash."
}

main "$@"

#!/usr/bin/env bash
# Signs a published release so the app will install it as an in-app update.
#   scripts/sign-release.sh <tag> [--replace]        for example: scripts/sign-release.sh build-36
#
# Dev tool: run by hand on the release owner's Mac, never by CI. It
#   1. downloads SHA256SUMS and TruongCleaner.zip from the release,
#   2. checks the ZIP against SHA256SUMS,
#   3. signs the exact SHA256SUMS bytes with the key in the login Keychain
#      (scripts/release-key.swift), and verifies the signature,
#   4. uploads SHA256SUMS.sig to the same release.
# It refuses when the release already has a SHA256SUMS.sig unless --replace is given.
#
# All work happens in a fresh folder under build/ that is removed on exit.
set -euo pipefail

REPO="iant4093/TruongCleaner"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf '%s\n' "$*"; }
fail() { printf 'sign-release: %s\n' "$*" >&2; exit 1; }

TAG=""
REPLACE=0
for arg in "$@"; do
  case "$arg" in
    --replace) REPLACE=1 ;;
    -*) fail "unknown option '$arg'. Usage: scripts/sign-release.sh <tag> [--replace]" ;;
    *)
      [ -z "$TAG" ] || fail "only one tag is allowed. Usage: scripts/sign-release.sh <tag> [--replace]"
      TAG="$arg"
      ;;
  esac
done
[ -n "$TAG" ] || fail "missing tag. Usage: scripts/sign-release.sh <tag> [--replace]"
[[ "$TAG" =~ ^build-[0-9]+$ ]] || fail "the tag must look like build-36 (got '$TAG')."

command -v gh >/dev/null 2>&1 || fail "the GitHub CLI (gh) is not installed."

mkdir -p "$ROOT/build"
WORK="$(mktemp -d "$ROOT/build/sign-release.XXXXXX")" || fail "could not create a temp folder under build/."

# Removes only the temp folder this run made, and only if it is where it should be.
cleanup() {
  case "$WORK" in
    "$ROOT"/build/sign-release.?*) rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT

# --- Does the release already have a signature? -------------------------------------------
assets="$(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name')" \
  || fail "could not read release $TAG from $REPO."
has_signature=0
if printf '%s\n' "$assets" | grep -Fxq "SHA256SUMS.sig"; then
  has_signature=1
fi
if [ "$has_signature" = "1" ] && [ "$REPLACE" = "0" ]; then
  fail "release $TAG already has SHA256SUMS.sig. Nothing was changed. Use --replace to sign it again."
fi

# --- Download and check the ZIP -------------------------------------------------------------
say "Downloading SHA256SUMS and TruongCleaner.zip from $TAG..."
gh release download "$TAG" -R "$REPO" -p SHA256SUMS -p TruongCleaner.zip --dir "$WORK" \
  || fail "could not download the release files."
[ -s "$WORK/SHA256SUMS" ] || fail "SHA256SUMS is empty or missing."
[ -s "$WORK/TruongCleaner.zip" ] || fail "TruongCleaner.zip is empty or missing."

zip_lines="$(awk '$2 == "TruongCleaner.zip" || $2 == "*TruongCleaner.zip"' "$WORK/SHA256SUMS" | wc -l | tr -d ' ')"
[ "$zip_lines" = "1" ] || fail "SHA256SUMS has $zip_lines entries for TruongCleaner.zip, expected exactly 1. Not signing."
(cd "$WORK" && shasum -a 256 -c --ignore-missing SHA256SUMS >/dev/null 2>&1) \
  || fail "TruongCleaner.zip does not match SHA256SUMS. Not signing."
say "TruongCleaner.zip matches SHA256SUMS."

# Only sign a ZIP that this repo's CI built: a file uploaded by hand has no build attestation.
gh attestation verify "$WORK/TruongCleaner.zip" -R "$REPO" >/dev/null 2>&1 \
  || fail "TruongCleaner.zip has no valid build attestation from $REPO's CI. Not signing."
commit="$(gh release view "$TAG" -R "$REPO" --json targetCommitish --jq .targetCommitish)" \
  || fail "could not read the commit of release $TAG."
say "TruongCleaner.zip was built by CI (release commit $commit)."

# --- Sign and upload --------------------------------------------------------------------------
(cd "$WORK" && swift "$ROOT/scripts/release-key.swift" sign SHA256SUMS) \
  || fail "signing failed. Nothing was uploaded."
[ -s "$WORK/SHA256SUMS.sig" ] || fail "no signature file was written. Nothing was uploaded."

if [ "$REPLACE" = "1" ]; then
  gh release upload "$TAG" "$WORK/SHA256SUMS.sig" -R "$REPO" --clobber \
    || fail "the upload failed. Check the release page."
  say "Uploaded SHA256SUMS.sig to $TAG, replacing the earlier one."
else
  gh release upload "$TAG" "$WORK/SHA256SUMS.sig" -R "$REPO" \
    || fail "the upload failed. Check the release page."
  say "Uploaded SHA256SUMS.sig to $TAG."
fi
say "Done. Build ${TAG#build-} can now be installed from inside the app."

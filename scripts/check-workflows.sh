#!/usr/bin/env bash
# actionlint, shellcheck, zizmor and Gitleaks, all pinned. Runs on ubuntu (CI) and on
# Apple Silicon macOS. Needs shellcheck and python3 on PATH.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tools="${RUNNER_TEMP:-$PWD/build}/workflow-tools"
mkdir -p "$tools"

os="$(uname -s)"
arch="$(uname -m)"
case "$os/$arch" in
  Linux/x86_64)
    actionlint_asset=actionlint_1.7.12_linux_amd64.tar.gz
    actionlint_sha=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    gitleaks_asset=gitleaks_8.30.1_linux_x64.tar.gz
    gitleaks_sha=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
    ;;
  Darwin/arm64)
    actionlint_asset=actionlint_1.7.12_darwin_arm64.tar.gz
    actionlint_sha=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    gitleaks_asset=gitleaks_8.30.1_darwin_arm64.tar.gz
    gitleaks_sha=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
    ;;
  *)
    echo "check-workflows: unsupported platform $os/$arch (need Linux x86_64 or macOS arm64)" >&2
    exit 2
    ;;
esac

sha256_check() {
  # macOS ships a sha256sum without --check, so choose by platform.
  if [ "$os" = Darwin ]; then
    shasum -a 256 --check
  else
    sha256sum --check
  fi
}

fetch() {
  local url="$1" checksum="$2" output="$3"
  curl --fail --location --silent --show-error --retry 3 "$url" -o "$output"
  printf '%s  %s\n' "$checksum" "$output" | sha256_check
}

fetch "https://github.com/rhysd/actionlint/releases/download/v1.7.12/$actionlint_asset" \
  "$actionlint_sha" "$tools/actionlint.tar.gz"
tar -xzf "$tools/actionlint.tar.gz" -C "$tools" actionlint
"$tools/actionlint" -color

shellcheck scripts/*.sh scripts/hooks/*.sh

python3 -m venv "$tools/venv"
"$tools/venv/bin/pip" --disable-pip-version-check install --quiet zizmor==1.31.1
"$tools/venv/bin/zizmor" --offline .github/workflows

fetch "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/$gitleaks_asset" \
  "$gitleaks_sha" "$tools/gitleaks.tar.gz"
tar -xzf "$tools/gitleaks.tar.gz" -C "$tools" gitleaks
"$tools/gitleaks" git --redact --no-banner --log-opts=--all .

#!/usr/bin/env bash
# Stub scripts, bash -c commands, and jq filters expand their own variables.
# shellcheck disable=SC2016
# All downloads in this suite use local files.
set -euo pipefail
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
root=$(cd "$(dirname "$0")/../../.." && pwd)
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
export HOME="$sb/home" APEXYARD_TELEMETRY=0
export APEXYARD_PREFIX="$sb/prefix" APEXYARD_VERSION=v9.8.7
export APEXYARD_RELEASE_BASE="file://$sb/releases"
export TMPDIR="$sb/tmp"
mkdir -p "$HOME" "$TMPDIR" "$sb/tools" "$sb/releases/$APEXYARD_VERSION"
passed=0 failed=0
check() {
  local label=$1
  shift
  if "$@"; then passed=$((passed + 1)); else
    echo "FAIL: $label"; failed=$((failed + 1))
  fi
}
refuses() { if "$@" > "$sb/error" 2>&1; then return 1; fi; }
# Stub identity so the install path also runs in root-owned test containers.
printf '#!/bin/sh\necho 1000\n' > "$sb/tools/id"
chmod +x "$sb/tools/id"
export PATH="$sb/tools:$PATH"
assets="$sb/releases/$APEXYARD_VERSION"
/bin/bash "$root/bin/build-release-assets.sh" "$APEXYARD_VERSION" "$assets"
archive="$assets/apexyard-$APEXYARD_VERSION.tar.gz"
cp "$archive" "$sb/original.tar.gz"
# Stamp every packaging channel from the same framework release.
stamped="$sb/stamped"
mkdir -p "$stamped"
cp "$archive.sha256" "$stamped/"
check stamp-packaging /bin/bash "$root/bin/stamp-packaging.sh" v9.8.7 "$stamped"
hash=$(awk '{print $1}' "$archive.sha256")
check formula-version grep -Fq 'version "9.8.7"' "$stamped/apexyard.rb"
check formula-url grep -Fq 'url "https://github.com/me2resh/apexyard/releases/download/v9.8.7/apexyard-v9.8.7.tar.gz"' "$stamped/apexyard.rb"
check formula-sha grep -Fq "sha256 \"$hash\"" "$stamped/apexyard.rb"
check package-version grep -Fq '"version": "9.8.7"' "$stamped/create-apexyard/package.json"
check installer-version grep -Fxq 'VERSION="9.8.7"' "$stamped/install.sh"
check no-placeholder bash -c '! grep -Fq __VERSION__ "$1"' _ "$stamped/install.sh"
check no-fixed-version bash -c '! grep -RFq 0.1.0 "$1/packaging" "$1/bin/apexyard"' _ "$root"
for version in 9.8.7 v9.8.7; do
  sh "$root/install.sh" --version "$version" --dry-run > "$sb/plan"
  check "normalized $version" grep -Fq "$APEXYARD_RELEASE_BASE/v9.8.7/apexyard-v9.8.7.tar.gz" "$sb/plan"
done
check installer-help bash -c 'sh "$1" --help | grep -Fq v5.11.0' _ "$root/install.sh"
fork=$(mktemp -d "$sb/fork.XXXXXX")
mkdir -p "$fork/.claude"
touch "$fork/onboarding.yaml" "$fork/apexyard.projects.yaml"
printf 'v5.11.0\n' > "$fork/.claude/framework-version"
check fork-version test "$(cd "$fork" && "$root/bin/apexyard" --version)" = 5.11.0

check install sh "$root/install.sh" > "$sb/install.out" 2>&1
check plan-first test "$(head -1 "$sb/install.out")" = Plan:
check installed-message grep -q '^Installed apexyard' "$sb/install.out"
check symlink test -L "$APEXYARD_PREFIX/bin/apexyard"
check help "$APEXYARD_PREFIX/bin/apexyard" --help
check no-sudo-command bash -c '! grep -Eq "^[[:space:]]*sudo([[:space:]]|$)" "$1"' _ "$root/install.sh"
check root-guard grep -Fq 'id -u' "$root/install.sh"
printf '#!/bin/sh\necho 0\n' > "$sb/tools/id"
check root-refused refuses sh "$root/install.sh" --dry-run
printf '#!/bin/sh\necho 1000\n' > "$sb/tools/id"
export APEXYARD_PREFIX="$sb/rejected"
printf tampered >> "$archive"
check mismatch refuses sh "$root/install.sh"
check mismatch-empty test ! -e "$APEXYARD_PREFIX"
check mismatch-clean test -z "$(ls -A "$TMPDIR")"
cp "$sb/original.tar.gz" "$archive"
mv "$archive.sha256" "$sb/checksum"
check missing-checksum refuses sh "$root/install.sh"
check missing-empty test ! -e "$APEXYARD_PREFIX"
check missing-clean test -z "$(ls -A "$TMPDIR")"
# A failing curl proves that dry-run cannot download.
printf '#!/bin/sh\ntouch "$HOME/curl-called"\nexit 1\n' > "$sb/tools/curl"
chmod +x "$sb/tools/curl"
check dry-run sh "$root/install.sh" --dry-run
check no-download test ! -e "$HOME/curl-called"
check no-dry-install test ! -e "$APEXYARD_PREFIX"
check placeholder refuses env -u APEXYARD_VERSION sh "$root/install.sh"
mkdir "$sb/unpacked"
tar -xzf "$archive" -C "$sb/unpacked"
bundle="$sb/unpacked/apexyard-$APEXYARD_VERSION"
check cli-version test "$("$bundle/bin/apexyard" --version)" = 9.8.7
check version-alias test "$("$bundle/bin/apexyard" version)" = 9.8.7
check version test "$(cat "$bundle/VERSION")" = "$APEXYARD_VERSION"
check stamp grep -Fq "APEXYARD_CLI_VERSION=\"${APEXYARD_VERSION#v}\"" "$bundle/bin/apexyard"
for file in apexyard apexyard-init.sh apexyard-update.sh _lib-telemetry.sh; do
  check "archive $file" test -f "$bundle/bin/$file"
done
if [ -f "$root/bin/_lib-ownership.sh" ]; then
  check ownership test -f "$bundle/bin/_lib-ownership.sh"
fi
(cd "$bundle" && find . -type f | LC_ALL=C sort) > "$sb/actual"
{
  printf './VERSION\n'
  for file in _lib-ownership.sh _lib-telemetry.sh apexyard apexyard-init.sh apexyard-update.sh; do
    [ -f "$root/bin/$file" ] && printf './bin/%s\n' "$file"
  done
} | LC_ALL=C sort > "$sb/expected"
check exact-archive cmp "$sb/expected" "$sb/actual"
/bin/bash "$root/bin/build-release-assets.sh" "$APEXYARD_VERSION" "$sb/rebuild"
check reproducible cmp "$archive" "$sb/rebuild/apexyard-$APEXYARD_VERSION.tar.gz"
workflow="$root/.github/workflows/release-cli.yml"
sed -n '/^on:/,/^permissions:/p' "$workflow" > "$sb/trigger"
check reusable grep -q '^  workflow_call:' "$sb/trigger"
check no-tag-push bash -c '! grep -Eq "^  push:|pull_request" "$1"' _ "$sb/trigger"
check top-read bash -c 'sed -n "/^permissions:/,/^jobs:/p" "$1" | grep -q "contents: read"' _ "$workflow"
check called-by-autotag grep -Fq 'uses: ./.github/workflows/release-cli.yml' "$root/.github/workflows/auto-tag-on-release-pr-merge.yml"
if command -v ruby >/dev/null 2>&1; then
  check formula ruby -c "$root/packaging/homebrew/apexyard.rb"
else echo 'NOTE: ruby is not available.'; fi
check installer-copy /bin/bash "$root/bin/check-bundled-installer.sh"
if command -v npm >/dev/null 2>&1; then
  (cd "$stamped/create-apexyard" && npm_config_cache="$sb/cache" npm_config_offline=true npm pack --ignore-scripts --pack-destination "$sb") > "$sb/npm.out" 2>&1
  check npm-pack test -f "$sb/create-apexyard-9.8.7.tgz"
  tar -tzf "$sb/create-apexyard-9.8.7.tgz" | LC_ALL=C sort > "$sb/npm-files"
  printf '%s\n' package/README.md package/bin/create-apexyard.js package/install.sh package/package.json | LC_ALL=C sort > "$sb/npm-expected"
  check npm-files cmp "$sb/npm-files" "$sb/npm-expected"
else echo 'NOTE: npm is not available.'; fi
if command -v node >/dev/null 2>&1; then
  launcher="$root/packaging/npm/create-apexyard/bin/create-apexyard.js"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "$HOME/args"\nexit 7\n' > "$sb/tools/apexyard"
  chmod +x "$sb/tools/apexyard"
  status=0
  node "$launcher" --org 'example org' > "$sb/launcher.out" 2>&1 || status=$?
  check npm-exit-status test "$status" -eq 7
  printf '%s\n' init --org 'example org' > "$sb/args-expected"
  check npm-arguments cmp "$HOME/args" "$sb/args-expected"
  rm "$sb/tools/apexyard" "$sb/tools/curl"
  mv "$sb/checksum" "$archive.sha256"
  export APEXYARD_PREFIX="$sb/npm-prefix"
  check npm-fallback node "$launcher" --help > "$sb/fallback.out" 2>&1
  check npm-installed test -L "$APEXYARD_PREFIX/bin/apexyard"
  check npm-init-help grep -q 'Usage: apexyard init' "$sb/fallback.out"
else echo 'NOTE: node is not available.'; fi
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

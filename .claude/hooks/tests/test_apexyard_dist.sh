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
cp "$archive" "$archive.sha256" "$stamped/"
check stamp-packaging /bin/bash "$root/bin/stamp-packaging.sh" v9.8.7 "$stamped"
# The npm package embeds the archive, so a changed archive must stop the stamp.
mkdir -p "$sb/stamp-bad"
cp "$archive" "$archive.sha256" "$sb/stamp-bad/"
printf tampered >> "$sb/stamp-bad/apexyard-v9.8.7.tar.gz"
check stamp-archive-mismatch refuses /bin/bash "$root/bin/stamp-packaging.sh" v9.8.7 "$sb/stamp-bad"
hash=$(awk '{print $1}' "$archive.sha256")
check formula-jq grep -Fq 'depends_on "jq"' "$stamped/apexyard.rb"
check formula-gh grep -Fq 'depends_on "gh"' "$stamped/apexyard.rb"
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
for file in apexyard apexyard-init.sh apexyard-update.sh apexyard-check.sh _lib-telemetry.sh _lib-repo-resolve.sh _lib-why-queue.sh; do
  check "archive $file" test -f "$bundle/bin/$file"
done
if [ -f "$root/bin/_lib-ownership.sh" ]; then
  check ownership test -f "$bundle/bin/_lib-ownership.sh"
fi
(cd "$bundle" && find . -type f | LC_ALL=C sort) > "$sb/actual"
{
  printf '%s\n' './VERSION' './.claude/skills/preflight/preflight.sh'
  for file in "$root/.claude/hooks/"_lib-*.sh; do
    printf './.claude/hooks/%s\n' "${file##*/}"
  done
  for file in _lib-ownership.sh _lib-telemetry.sh _lib-repo-resolve.sh _lib-why-queue.sh apexyard apexyard-init.sh apexyard-update.sh apexyard-check.sh; do
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
if command -v npm >/dev/null 2>&1; then
  (cd "$stamped/create-apexyard" && npm_config_cache="$sb/cache" npm_config_offline=true npm pack --ignore-scripts --pack-destination "$sb") > "$sb/npm.out" 2>&1
  check npm-pack test -f "$sb/create-apexyard-9.8.7.tgz"
  tar -tzf "$sb/create-apexyard-9.8.7.tgz" | LC_ALL=C sort > "$sb/npm-files"
  printf '%s\n' package/README.md package/apexyard-v9.8.7.tar.gz package/bin/create-apexyard.js package/package.json | LC_ALL=C sort > "$sb/npm-expected"
  check npm-files cmp "$sb/npm-files" "$sb/npm-expected"
else echo 'NOTE: npm is not available.'; fi
# create-apexyard pins the formula tag and SHA-256 and has no install scripts (AgDR-0300).
pkg="$stamped/create-apexyard"
check npm-pinned-tag test "$(jq -r .apexyard.tag "$pkg/package.json")" = v9.8.7
check npm-pinned-sha test "$(jq -r .apexyard.sha256 "$pkg/package.json")" = "$hash"
check npm-same-archive cmp "$archive" "$pkg/apexyard-v9.8.7.tar.gz"
check npm-no-scripts jq -e 'has("scripts") | not' "$pkg/package.json"
check npm-no-dependencies jq -e '[has("dependencies"), has("optionalDependencies"), has("peerDependencies"), has("bundleDependencies")] | any | not' "$pkg/package.json"
check npm-engines jq -e '.engines.node | test("^>=[0-9]+$")' "$pkg/package.json"
check npm-repository jq -e '.repository.url == "git+https://github.com/me2resh/apexyard.git"' "$pkg/package.json"
if command -v node >/dev/null 2>&1; then
  launcher="$pkg/bin/create-apexyard.js"
  export APEXYARD_PREFIX="$sb/npm-prefix"
  work=$(mktemp -d "$sb/npx.XXXXXX")
  # The curl stub above still fails. A download attempt cannot pass these checks.
  status=0
  (cd "$work" && node "$launcher" --help < /dev/null) > "$sb/npm-help.out" 2>&1 || status=$?
  check npm-help-status test "$status" -eq 0
  check npm-help-usage grep -q 'Usage: apexyard init' "$sb/npm-help.out"
  check npm-help-no-install test ! -e "$APEXYARD_PREFIX"
  check npm-help-clean-dir test -z "$(ls -A "$work")"
  # No terminal and no flags: name each missing flag and create nothing.
  status=0
  (cd "$work" && node "$launcher" < /dev/null) > "$sb/npm-missing.out" 2>&1 || status=$?
  check npm-missing-status test "$status" -eq 2
  check npm-missing-flags grep -Fq 'Missing flags: --org --name.' "$sb/npm-missing.out"
  status=0
  (cd "$work" && node "$launcher" --org example < /dev/null) > "$sb/npm-missing.out" 2>&1 || status=$?
  check npm-missing-name-status test "$status" -eq 2
  check npm-missing-name grep -Fq 'Missing flags: --name.' "$sb/npm-missing.out"
  check npm-missing-no-install test ! -e "$APEXYARD_PREFIX"
  check npm-missing-clean-dir test -z "$(ls -A "$work")"
  # With the flags, the launcher installs the pinned CLI and runs init.
  printf '#!/bin/sh\n[ "$1 $2" != "repo view" ] || exit 1\necho example\n' > "$sb/tools/gh-stub"
  chmod +x "$sb/tools/gh-stub"
  status=0
  (cd "$work" && APEXYARD_GH="$sb/tools/gh-stub" node "$launcher" --org example --name ops --dry-run < /dev/null) > "$sb/npm-init.out" 2>&1 || status=$?
  check npm-init-status test "$status" -eq 0
  check npm-init-plan grep -Fq 'This is what will happen' "$sb/npm-init.out"
  # init clones the framework at the package tag, not at main.
  check npm-init-pinned-ref grep -Fq 'Download ApexYard (v9.8.7)' "$sb/npm-init.out"
  check npm-installed test -x "$APEXYARD_PREFIX/share/apexyard/v9.8.7/bin/apexyard"
  check npm-symlink test "$(readlink "$APEXYARD_PREFIX/bin/apexyard")" = "$APEXYARD_PREFIX/share/apexyard/v9.8.7/bin/apexyard"
  check npm-cli-version test "$("$APEXYARD_PREFIX/bin/apexyard" --version)" = 9.8.7
  check npm-dry-run-clean-dir test -z "$(ls -A "$work")"
  check npm-no-download test ! -e "$HOME/curl-called"
  # A second run uses the installed CLI again.
  status=0
  (cd "$work" && APEXYARD_GH="$sb/tools/gh-stub" node "$launcher" --org example --name ops --dry-run < /dev/null) > "$sb/npm-init.out" 2>&1 || status=$?
  check npm-rerun-status test "$status" -eq 0
  # A framework repo without the package tag stops init before GitHub (fail closed).
  git init -q "$sb/framework"
  git -C "$sb/framework" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$HOME/gh-calls"\n[ "$1 $2" != "repo view" ] || exit 1\necho example\n' > "$sb/tools/gh-log"
  chmod +x "$sb/tools/gh-log"
  status=0
  (cd "$work" && APEXYARD_GH="$sb/tools/gh-log" APEXYARD_FRAMEWORK_URL="$sb/framework" node "$launcher" --org example --name ops --dir "$work/ops" < /dev/null) > "$sb/npm-notag.out" 2>&1 || status=$?
  check npm-missing-tag-fails test "$status" -ne 0
  check npm-missing-tag-clone grep -Fq 'v9.8.7 not found' "$sb/npm-notag.out"
  check npm-missing-tag-no-dir test ! -e "$work/ops"
  check npm-missing-tag-no-repo bash -c '! grep -q "^repo create" "$1"' _ "$HOME/gh-calls"
  # A changed archive stops the launcher before it extracts a file.
  cp -R "$pkg" "$sb/tampered"
  printf tampered >> "$sb/tampered/apexyard-v9.8.7.tar.gz"
  export APEXYARD_PREFIX="$sb/npm-tampered"
  status=0
  (cd "$work" && node "$sb/tampered/bin/create-apexyard.js" --org example --name ops --dry-run < /dev/null) > "$sb/npm-tampered.out" 2>&1 || status=$?
  check npm-tampered-status test "$status" -eq 1
  check npm-tampered-message grep -Fq 'checksum mismatch' "$sb/npm-tampered.out"
  check npm-tampered-no-install test ! -e "$APEXYARD_PREFIX"
  # The unstamped source package refuses to run.
  status=0
  node "$root/packaging/npm/create-apexyard/bin/create-apexyard.js" --help > "$sb/npm-unstamped.out" 2>&1 || status=$?
  check npm-unstamped-status test "$status" -eq 1
  check npm-unstamped-message grep -Fq 'no stamped release' "$sb/npm-unstamped.out"
else echo 'NOTE: node is not available.'; fi
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

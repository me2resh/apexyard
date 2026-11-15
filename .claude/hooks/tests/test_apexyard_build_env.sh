#!/usr/bin/env bash
# Tests for bin/apexyard-build-env (me2resh/apexyard#2070 step 2).
set -uo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
sb=$(mktemp -d)
trap 'rm -rf "$sb"' EXIT
export HOME="$sb/home"
mkdir -p "$HOME"
unset XDG_CACHE_HOME APEXYARD_BUILD_CACHE npm_config_cache CARGO_TARGET_DIR GOCACHE
script="$root/bin/apexyard-build-env"
passed=0 failed=0
check() {
  local label=$1
  shift
  if "$@"; then passed=$((passed + 1)); else echo "FAIL: $label"; failed=$((failed + 1)); fi
}
has() { grep -q -- "$1" "$sb/out"; }
lacks() { ! grep -q -- "$1" "$sb/out"; }

# Build a repo and a linked worktree inside a subshell with a literal cd.
mkdir -p "$sb/repo"
(
  cd "$sb/repo" || exit 1
  git init -q .
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git worktree add -q "$sb/wt" -b other
) >/dev/null 2>&1

run() { # run <dir> [env...] ; output to $sb/out
  local d=$1
  shift
  (cd "$d" || exit 1; env "$@" bash "$script") > "$sb/out" 2>/dev/null
}

run "$sb/repo" X=1
check "default dir" has "export npm_config_cache=$HOME/.cache/apexyard/build/npm"
check "all seven vars" test "$(wc -l < "$sb/out")" -eq 7
cp "$sb/out" "$sb/main.out"
run "$sb/wt" X=1
check "worktrees share one target folder" test "$(grep CARGO_TARGET_DIR "$sb/main.out")" = "$(grep CARGO_TARGET_DIR "$sb/out")"

run "$sb/repo" APEXYARD_BUILD_CACHE=off
check "env off prints nothing" test ! -s "$sb/out"
run "$sb/repo" APEXYARD_BUILD_CACHE=/srv/c
check "env path used" has "export GOCACHE=/srv/c/go-build"
run "$sb/repo" npm_config_cache=/mine
check "existing var kept" lacks npm_config_cache
check "other vars still set" has GOCACHE
run "$sb/repo" XDG_CACHE_HOME=/x
check "xdg honoured" has "/x/apexyard/build/npm"
run "$sb" X=1
check "outside a repo uses default key" has "cargo-target/default"

rc=0; (cd "$sb/repo" || exit 1; APEXYARD_BUILD_CACHE=rel bash "$script" >/dev/null 2>&1) || rc=$?
check "relative path exit 2" test "$rc" -eq 2
rc=0; (cd "$sb/repo" || exit 1; APEXYARD_BUILD_CACHE='/a b;x' bash "$script" >/dev/null 2>&1) || rc=$?
check "unsafe char exit 2" test "$rc" -eq 2
rc=0; (cd "$sb/repo" || exit 1; bash "$script" --bad >/dev/null 2>&1) || rc=$?
check "bad arg exit 2" test "$rc" -eq 2
(cd "$sb/repo" || exit 1; bash "$script" --show) > "$sb/out" 2>/dev/null
check "show enabled" has "enabled=on"
check "no folder created" test ! -e "$HOME/.cache"

echo "passed=$passed failed=$failed"
[ "$failed" -eq 0 ]

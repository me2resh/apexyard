#!/bin/bash
# Regression test for me2resh/apexyard#1062 — the cwd-derived branch of the
# trust-chain self-location must be anchored, not only the git-derived fallback.
#
# #1033/#1061 anchored the `git rev-parse` FALLBACK branch. But the cwd branch runs
# FIRST: under a non-bash shell BASH_SOURCE is unset, so `dirname "" -> "."` and the
# derived dir becomes the CALLER's cwd. If that cwd directly contains the sibling lib,
# the `[ ! -f "$dir/<sibling>" ]` guard is false, the anchored fallback never runs, and
# an impostor cwd wins UNANCHORED. #1062 discards a cwd-derived dir when BASH_SOURCE is
# empty, forcing it through the same anchor; a genuine BASH_SOURCE path is kept as-is.
#
# This bug only reproduces under a shell that leaves BASH_SOURCE unset (zsh). The #1033
# test's `. /dev/stdin` trick yields BASH_SOURCE[0]=/dev/stdin (dirname -> /dev), which
# does NOT reproduce the cwd degradation — so this regression lives in its own
# zsh-guarded file, alongside test_tracker_zsh_self_location.sh.
#
# Representative site: _lib-tracker.sh :: _tracker_load_config_lib (sources
# _lib-read-config.sh) plus _lib-fresh-fork.sh (a top-level self-location). The same
# guard is applied uniformly to all nine self-location sites (see the #1062 diff).
set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER_LIB="$HOOKS_DIR/_lib-tracker.sh"
FRESH_FORK_LIB="$HOOKS_DIR/_lib-fresh-fork.sh"

PASS=0
FAIL=0
FAILED=""
ok()  { PASS=$((PASS + 1)); echo "PASS [$1]"; }
bad() { FAIL=$((FAIL + 1)); FAILED="${FAILED}$1 "; echo "FAIL [$1]: $2" >&2; }

if ! command -v zsh >/dev/null 2>&1; then
  echo "SKIP: zsh not installed — #1062 needs a non-bash sourcing shell to reproduce"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A decoy sibling that shouts if it is sourced. Placed in each fixture's .claude/hooks/.
decoy_read_config() { # <dir> <marker-var> <marker-val>
  cat > "$1/_lib-read-config.sh" <<EOF
$2=$3
config_get_or() { :; }
EOF
}

# impostor NON-fork repo: ships .claude/hooks/_lib-read-config.sh but no fork anchor
IMP="$TMP/impostor"
mkdir -p "$IMP/.claude/hooks"
( cd "$IMP" && git init -q && git config user.email t@t && git config user.name t )
decoy_read_config "$IMP/.claude/hooks" IMPOSTOR_CONFIG 1

# genuine fork, v2 layout: .apexyard-fork anchor
FORK2="$TMP/fork-v2"
mkdir -p "$FORK2/.claude/hooks"
( cd "$FORK2" && git init -q && git config user.email t@t && git config user.name t )
: > "$FORK2/.apexyard-fork"
decoy_read_config "$FORK2/.claude/hooks" FORK_CONFIG v2

# genuine fork, v1 layout: onboarding.yaml + apexyard.projects.yaml pair
FORK1="$TMP/fork-v1"
mkdir -p "$FORK1/.claude/hooks"
( cd "$FORK1" && git init -q && git config user.email t@t && git config user.name t )
: > "$FORK1/onboarding.yaml"
: > "$FORK1/apexyard.projects.yaml"
decoy_read_config "$FORK1/.claude/hooks" FORK_CONFIG v1

# Source the lib under zsh from <cwd>, call the loader, report which sibling won.
tracker_zsh() {
  ( cd "$1" && zsh -c "source '$TRACKER_LIB'; _tracker_load_config_lib >/dev/null 2>&1; \
      echo \"IMPOSTOR_CONFIG=\${IMPOSTOR_CONFIG:-unset} FORK_CONFIG=\${FORK_CONFIG:-unset}\"" )
}

# Case 1 — the #1062 regression: an impostor cwd must NOT load its sibling (zsh).
out="$(tracker_zsh "$IMP/.claude/hooks")"
case "$out" in
  *"IMPOSTOR_CONFIG=unset"*) ok "impostor cwd (zsh): sibling not sourced from cwd" ;;
  *) bad "impostor cwd (zsh): sibling not sourced from cwd" "impostor lib was sourced: $out" ;;
esac

# Case 2 — a genuine v2 fork must still resolve under zsh (over-strictness guard).
out="$(tracker_zsh "$FORK2/.claude/hooks")"
case "$out" in
  *"FORK_CONFIG=v2"*) ok "v2 fork cwd (zsh): sibling still loads via the anchor" ;;
  *) bad "v2 fork cwd (zsh): sibling still loads via the anchor" "v2 fork did not resolve: $out" ;;
esac

# Case 3 — a genuine v1 fork must still resolve under zsh (both layouts).
out="$(tracker_zsh "$FORK1/.claude/hooks")"
case "$out" in
  *"FORK_CONFIG=v1"*) ok "v1 fork cwd (zsh): sibling still loads via the anchor" ;;
  *) bad "v1 fork cwd (zsh): sibling still loads via the anchor" "v1 fork did not resolve: $out" ;;
esac

# Case 4 — under bash a genuine BASH_SOURCE path is kept (never gated): sourcing the
# real lib from an impostor cwd loads the REAL sibling, never the impostor's.
out="$( cd "$IMP/.claude/hooks" && bash -c "source '$TRACKER_LIB'; _tracker_load_config_lib >/dev/null 2>&1; \
    echo \"IMPOSTOR_CONFIG=\${IMPOSTOR_CONFIG:-unset}\"" )"
case "$out" in
  *"IMPOSTOR_CONFIG=unset"*) ok "impostor cwd (bash): genuine BASH_SOURCE kept, impostor not loaded" ;;
  *) bad "impostor cwd (bash): genuine BASH_SOURCE kept" "impostor lib was sourced under bash: $out" ;;
esac

# Case 5 — a top-level self-location site (_lib-fresh-fork.sh runs at source time)
# is guarded too: sourcing it from an impostor cwd under zsh must not load the cwd sibling.
out="$( cd "$IMP/.claude/hooks" && zsh -c "source '$FRESH_FORK_LIB' >/dev/null 2>&1; \
    echo \"IMPOSTOR_CONFIG=\${IMPOSTOR_CONFIG:-unset}\"" )"
case "$out" in
  *"IMPOSTOR_CONFIG=unset"*) ok "impostor cwd (zsh, top-level site): sibling not sourced from cwd" ;;
  *) bad "impostor cwd (zsh, top-level site): sibling not sourced from cwd" "impostor lib was sourced: $out" ;;
esac

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAILED"
  exit 1
fi
echo "All $PASS checks passed."

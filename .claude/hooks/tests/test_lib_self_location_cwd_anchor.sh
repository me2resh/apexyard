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

# ==========================================================================
# me2resh/apexyard#1102 / AgDR-0118 — the four remaining spellings
# ==========================================================================
# #1100's security review found FOUR more self-location sites the #1062/#1100
# grep missed, each a DIFFERENT spelling of the same bug:
#   _lib-extract-push-ref.sh  :: ${BASH_SOURCE[0]}        (no `:-` at all)
#   _lib-git-hooks-path.sh    :: ${BASH_SOURCE[0]:-$0}    (fake fix via $0)
#   _lib-protected-branches.sh:: ${BASH_SOURCE[0]:-$0}    (same, inside a fn)
#   _lib-read-config.sh       :: ${BASH_SOURCE[0]:-}      (anchor-check
#                                                           missing on the
#                                                           unanchored
#                                                           git-toplevel
#                                                           FALLBACK, not
#                                                           the sourcing
#                                                           step itself)
# #1102 centralizes the fix behind resolve_anchored_lib_dir() in
# _lib-ops-root.sh. Each case below proves BASE (HEAD, pre-fix, from git
# history) fails and FIX (this worktree's edited copy) passes, using a
# discriminating impostor sibling reachable via cwd.
BASE_REF="${APEXYARD_TEST_BASE_REF:-HEAD}"
BASE_DIR="$TMP/base-libs"
mkdir -p "$BASE_DIR"
for f in _lib-extract-push-ref.sh _lib-git-hooks-path.sh _lib-protected-branches.sh _lib-read-config.sh _lib-ops-root.sh _lib-strip-heredoc.sh _lib-path-resolve.sh; do
  git -C "$HOOKS_DIR/.." show "$BASE_REF:.claude/hooks/$f" > "$BASE_DIR/$f" 2>/dev/null || true
done

FIX_EXTRACT_PUSH_REF="$HOOKS_DIR/_lib-extract-push-ref.sh"
FIX_GIT_HOOKS_PATH="$HOOKS_DIR/_lib-git-hooks-path.sh"
FIX_PROTECTED_BRANCHES="$HOOKS_DIR/_lib-protected-branches.sh"
FIX_READ_CONFIG="$HOOKS_DIR/_lib-read-config.sh"

# --------------------------------------------------------------------
# Case 6/7 — _lib-extract-push-ref.sh: impostor cwd ships a decoy
# _lib-strip-heredoc.sh. BASE has no `:-` guard at all on BASH_SOURCE[0];
# FIX refuses to source anything when BASH_SOURCE is unusable.
# --------------------------------------------------------------------
IMP2="$TMP/impostor-push-ref"
mkdir -p "$IMP2/.claude/hooks"
( cd "$IMP2" && git init -q && git config user.email t@t && git config user.name t )
cat > "$IMP2/.claude/hooks/_lib-strip-heredoc.sh" <<'EOF'
IMPOSTOR_HEREDOC=1
strip_heredoc_bodies() { printf '%s' "$1"; }
EOF

push_ref_zsh() { # <lib-file> <cwd>
  ( cd "$2" && zsh -c "source '$1' >/dev/null 2>&1; echo \"IMPOSTOR_HEREDOC=\${IMPOSTOR_HEREDOC:-unset}\"" )
}

if [ -s "$BASE_DIR/_lib-extract-push-ref.sh" ]; then
  out="$(push_ref_zsh "$BASE_DIR/_lib-extract-push-ref.sh" "$IMP2/.claude/hooks")"
  case "$out" in
    *"IMPOSTOR_HEREDOC=1"*) ok "extract-push-ref BASE (zsh): impostor sourced (expected — proves the bug)" ;;
    *) bad "extract-push-ref BASE (zsh): impostor sourced (expected — proves the bug)" "BASE did NOT reproduce the bug: $out" ;;
  esac
fi

out="$(push_ref_zsh "$FIX_EXTRACT_PUSH_REF" "$IMP2/.claude/hooks")"
case "$out" in
  *"IMPOSTOR_HEREDOC=unset"*) ok "extract-push-ref FIX (zsh): impostor NOT sourced" ;;
  *) bad "extract-push-ref FIX (zsh): impostor NOT sourced" "impostor was sourced: $out" ;;
esac

# A genuine fork sourced under BASH (not zsh) still resolves normally --
# the fix only changes behavior when BASH_SOURCE is unusable in the first
# place (see resolve_anchored_lib_dir's "NOT anchored to an ops-root
# marker" comment: under zsh this lib now fails closed to "self-location
# unavailable" even for a genuine fork, matching the same "run under bash,
# not zsh" trade-off _lib-read-config.sh already documents; it is not
# retested here for over-strictness because that would be asserting the
# WRONG expectation).
out="$( cd "$IMP2/.claude/hooks" && bash -c "source '$FIX_EXTRACT_PUSH_REF' >/dev/null 2>&1; echo \"IMPOSTOR_HEREDOC=\${IMPOSTOR_HEREDOC:-unset}\"" )"
case "$out" in
  *"IMPOSTOR_HEREDOC=unset"*) ok "extract-push-ref FIX (bash): genuine BASH_SOURCE kept, impostor not loaded" ;;
  *) bad "extract-push-ref FIX (bash): genuine BASH_SOURCE kept, impostor not loaded" "impostor was sourced under bash: $out" ;;
esac

# --------------------------------------------------------------------
# Case 8/9 — _lib-git-hooks-path.sh: impostor cwd ships a decoy
# _lib-path-resolve.sh. BASE's `:-$0` is a fake fix; FIX refuses it.
#
# The self-location line here runs at SOURCE time (top level, not inside a
# function). zsh sets $0 to the sourced file's OWN path when you `source
# /an/absolute/path` -- which happens to make `:-$0` look like it works if
# you test it that way. The real hazard is $0 "as typed": when the lib is
# sourced by a BARE, directory-less name (e.g. a caller does `source
# _lib-git-hooks-path.sh` after `cd`ing into its directory -- a completely
# normal invocation shape), $0 has no directory component, dirname("<bare
# name>") -> ".", and that's the cwd substitution bug. So the fixture
# copies the lib INTO the impostor cwd under its real name and sources it
# bare, matching that real shape.
# --------------------------------------------------------------------
IMP3="$TMP/impostor-git-hooks-path"
mkdir -p "$IMP3"
( cd "$IMP3" && git init -q && git config user.email t@t && git config user.name t )
cat > "$IMP3/_lib-path-resolve.sh" <<'EOF'
IMPOSTOR_PATH_RESOLVE=1
_resolve_real_path() { printf '%s' "$1"; }
EOF

ghp_zsh() { # <lib-file> <cwd>
  cp "$1" "$2/_lib-git-hooks-path.sh"
  ( cd "$2" && zsh -c "source _lib-git-hooks-path.sh >/dev/null 2>&1; echo \"IMPOSTOR_PATH_RESOLVE=\${IMPOSTOR_PATH_RESOLVE:-unset}\"" )
}

if [ -s "$BASE_DIR/_lib-git-hooks-path.sh" ]; then
  out="$(ghp_zsh "$BASE_DIR/_lib-git-hooks-path.sh" "$IMP3")"
  case "$out" in
    *"IMPOSTOR_PATH_RESOLVE=1"*) ok "git-hooks-path BASE (zsh): impostor sourced (expected — proves the bug)" ;;
    *) bad "git-hooks-path BASE (zsh): impostor sourced (expected — proves the bug)" "BASE did NOT reproduce the bug: $out" ;;
  esac
fi

out="$(ghp_zsh "$FIX_GIT_HOOKS_PATH" "$IMP3")"
case "$out" in
  *"IMPOSTOR_PATH_RESOLVE=unset"*) ok "git-hooks-path FIX (zsh): impostor NOT sourced" ;;
  *) bad "git-hooks-path FIX (zsh): impostor NOT sourced" "impostor was sourced: $out" ;;
esac

# A genuine fork sourced under BASH (not zsh) still resolves normally --
# see the note above extract-push-ref's equivalent case for why this is
# tested under bash, not re-tested for over-strictness under zsh.
GFORK3="$TMP/genuine-git-hooks-path"
mkdir -p "$GFORK3"
( cd "$GFORK3" && git init -q && git config user.email t@t && git config user.name t )
: > "$GFORK3/.apexyard-fork"
mkdir -p "$GFORK3/.claude/hooks"
cp "$HOOKS_DIR/_lib-ops-root.sh" "$GFORK3/.claude/hooks/_lib-ops-root.sh"
cp "$FIX_GIT_HOOKS_PATH" "$GFORK3/.claude/hooks/_lib-git-hooks-path.sh"
cat > "$GFORK3/.claude/hooks/_lib-path-resolve.sh" <<'EOF'
GENUINE_PATH_RESOLVE=1
_resolve_real_path() { printf '%s' "$1"; }
EOF
out="$( cd "$GFORK3/.claude/hooks" && bash -c "source _lib-git-hooks-path.sh >/dev/null 2>&1; echo \"GENUINE_PATH_RESOLVE=\${GENUINE_PATH_RESOLVE:-unset}\"" )"
case "$out" in
  *"GENUINE_PATH_RESOLVE=1"*) ok "git-hooks-path FIX (bash): genuine fork still resolves (bare source)" ;;
  *) bad "git-hooks-path FIX (bash): genuine fork still resolves (bare source)" "genuine fork did not resolve: $out" ;;
esac

# --------------------------------------------------------------------
# Case 10/11 — _lib-protected-branches.sh: same `:-$0` fake fix, but the
# self-location runs INSIDE a function (protected_branch_regex), not at
# top level. Decoy _lib-read-config.sh reports an impostor regex.
# --------------------------------------------------------------------
IMP4="$TMP/impostor-protected-branches"
mkdir -p "$IMP4/.claude/hooks"
( cd "$IMP4" && git init -q && git config user.email t@t && git config user.name t )
cat > "$IMP4/.claude/hooks/_lib-read-config.sh" <<'EOF'
config_get() { echo "impostor-branch"; }
EOF

pb_zsh() { # <lib-file> <cwd>
  ( cd "$2" && zsh -c "source '$1'; protected_branch_regex" )
}

if [ -s "$BASE_DIR/_lib-protected-branches.sh" ]; then
  out="$(pb_zsh "$BASE_DIR/_lib-protected-branches.sh" "$IMP4/.claude/hooks")"
  case "$out" in
    *"impostor-branch"*) ok "protected-branches BASE (zsh): impostor sourced (expected — proves the bug)" ;;
    *) bad "protected-branches BASE (zsh): impostor sourced (expected — proves the bug)" "BASE did NOT reproduce the bug: $out" ;;
  esac
fi

out="$(pb_zsh "$FIX_PROTECTED_BRANCHES" "$IMP4/.claude/hooks")"
case "$out" in
  *"impostor-branch"*) bad "protected-branches FIX (zsh): impostor NOT sourced" "impostor was sourced: $out" ;;
  *"main|master|dev|develop"*) ok "protected-branches FIX (zsh): impostor NOT sourced, safe default used" ;;
  *) bad "protected-branches FIX (zsh): impostor NOT sourced" "unexpected output: $out" ;;
esac

# --------------------------------------------------------------------
# Case 12/13 — _lib-read-config.sh: the vulnerable spot is the UNANCHORED
# git-toplevel FALLBACK, not the _lib-ops-root.sh sourcing step. An
# impostor repo (real git repo, no ops-root anchor) must not silently
# resolve as config root under zsh in FIX; BASE always trusted it.
# --------------------------------------------------------------------
IMP5="$TMP/impostor-read-config"
# NOTE on scope (see AgDR-0118's "divergence from the initial brief"
# section): the vulnerable step in _lib-read-config.sh is `_config_repo_root`
# sourcing _lib-ops-root.sh via an unanchored lib_dir -- NOT the eventual
# `git rev-parse --show-toplevel` fallback, which this fix deliberately
# leaves UNCHANGED (git-repo-scoped, not ops-root-anchored — see that
# function's own "FALLBACK — DELIBERATELY LEFT git-repo-scoped" comment).
# So the discriminating case here is a decoy `_lib-ops-root.sh`, exactly
# the same shape as the other three sites, not the fallback's anchoring.
mkdir -p "$IMP5/.claude/hooks"
( cd "$IMP5" && git init -q && git config user.email t@t && git config user.name t )
cat > "$IMP5/.claude/hooks/_lib-ops-root.sh" <<'EOF'
DECOY_OPS_ROOT=1
resolve_ops_root() { printf '%s' "DECOY-ROOT-HIJACKED"; }
EOF

rc_zsh() { # <lib-file> <cwd>
  ( cd "$2" && zsh -c "source '$1' >/dev/null 2>&1; _config_repo_root" )
}

if [ -s "$BASE_DIR/_lib-read-config.sh" ]; then
  out="$(rc_zsh "$BASE_DIR/_lib-read-config.sh" "$IMP5/.claude/hooks" 2>/dev/null)"
  case "$out" in
    *"DECOY-ROOT-HIJACKED"*) ok "read-config BASE (zsh): decoy _lib-ops-root.sh sourced (expected — proves the bug)" ;;
    *) bad "read-config BASE (zsh): decoy _lib-ops-root.sh sourced (expected — proves the bug)" "BASE did NOT reproduce the bug: got '$out'" ;;
  esac
fi

out="$(rc_zsh "$FIX_READ_CONFIG" "$IMP5/.claude/hooks")"
case "$out" in
  *"DECOY-ROOT-HIJACKED"*) bad "read-config FIX (zsh): decoy _lib-ops-root.sh NOT sourced" "decoy was sourced: $out" ;;
  *"$IMP5"*) ok "read-config FIX (zsh): decoy NOT sourced, falls through to the unchanged git-toplevel fallback (the impostor's own real repo, not the decoy's fake root — correct, not a leak: it's reading ITS OWN config)" ;;
  *) bad "read-config FIX (zsh): decoy NOT sourced" "unexpected: got '$out'" ;;
esac

# A genuine anchored fork's config root still resolves normally under bash
# (the ops-root walk-up itself is untouched by #1102 — only the self-
# location bootstrap that reaches it changed).
GFORK2="$TMP/genuine-read-config"
mkdir -p "$GFORK2/.claude/hooks"
( cd "$GFORK2" && git init -q && git config user.email t@t && git config user.name t )
: > "$GFORK2/.apexyard-fork"
cp "$HOOKS_DIR/_lib-ops-root.sh" "$GFORK2/.claude/hooks/_lib-ops-root.sh"
out="$( cd "$GFORK2/.claude/hooks" && bash -c "source '$FIX_READ_CONFIG' >/dev/null 2>&1; _config_repo_root" )"
case "$out" in
  *"$GFORK2"*) ok "read-config FIX (bash): genuine anchored fork still resolves" ;;
  *) bad "read-config FIX (bash): genuine anchored fork still resolves" "got: '$out'" ;;
esac

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAILED"
  exit 1
fi
echo "All $PASS checks passed."

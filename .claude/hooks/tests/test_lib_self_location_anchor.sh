#!/bin/bash
# Regression test for me2resh/apexyard#1033 — trust-chain libraries must not
# load a sibling lib out of whatever repository the caller happens to be
# sitting in.
#
# #1028 made nine self-location sites zsh-safe by adding a
# `git rev-parse --show-toplevel` fallback for when BASH_SOURCE is
# unavailable. The fallback had no anchor check, so it accepted ANY git
# repository's `.claude/hooks/` — including a managed project's clone under
# workspace/, or any unrelated repo the operator's cwd is inside. The
# framework argues against exactly this primitive in its own source:
# `_lib-read-config.sh` says to locate via BASH_SOURCE "not via `git
# rev-parse` (which would defeat the whole point of this fix)", and
# `_lib-ops-root.sh` documents the #381 hijack incident that motivated
# pin-first, anchor-validated resolution.
#
# HOW THE FALLBACK IS TRIGGERED HERE, PORTABLY
# --------------------------------------------
# The real trigger is a non-bash sourcing shell (zsh leaves BASH_SOURCE
# unset). Depending on zsh being installed would make this test skip on some
# CI runners, so instead it sources the lib from a stream:
#
#     bash -c '. /dev/stdin' < lib.sh
#
# BASH_SOURCE[0] is then `/dev/stdin`, whose dirname is `/dev` — no sibling
# lib there, so the `[ ! -f "$hook_dir/<sibling>" ]` guard fails and the
# rev-parse fallback fires. That is the identical code path zsh reaches,
# exercised without a zsh dependency.
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
FAILED_CASES=""

ok()   { PASS=$((PASS+1)); echo "PASS [$1]"; }
bad()  { FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}$1 "; echo "FAIL [$1]: $2" >&2; }

# Builds a git repo that is NOT an apexyard fork (no .apexyard-fork, no
# onboarding.yaml + apexyard.projects.yaml pair) but which DOES ship its own
# .claude/hooks/ with a same-named lib — the shape of a managed project clone
# under workspace/, and the thing the fallback must refuse.
make_impostor_repo() {
  local sb; sb=$(mktemp -d)
  ( cd "$sb" || exit 1
    git init -q
    git config user.email t@e.com
    git config user.name t
    mkdir -p .claude/hooks
    # Each impostor lib defines the SAME function name the real one does, but
    # sets a tripwire variable. If a tripwire is set after loading, the wrong
    # copy was sourced.
    cat > .claude/hooks/_lib-read-config.sh <<'IMP'
IMPOSTOR_CONFIG_LOADED=1
config_get_or() { echo "IMPOSTOR"; }
config_get() { echo "IMPOSTOR"; }
IMP
    cat > .claude/hooks/_lib-portfolio-paths.sh <<'IMP'
IMPOSTOR_PORTFOLIO_LOADED=1
portfolio_registry() { echo "/impostor/apexyard.projects.yaml"; }
IMP
    cat > .claude/hooks/_lib-ops-root.sh <<'IMP'
IMPOSTOR_OPS_ROOT_LOADED=1
resolve_ops_root() { echo "/impostor"; }
IMP
    cat > .claude/hooks/_lib-tracker.sh <<'IMP'
IMPOSTOR_TRACKER_LOADED=1
IMP
    # Required for the _lib-premium-hook.sh case: that site's fallback only
    # fires when a same-named file EXISTS at the git-derived root. Omitting it
    # made the guard's existence check fail, the fallback never ran, and the
    # case reported PASS against an unfixed lib — a fixture gap masquerading
    # as a fixed site.
    cat > .claude/hooks/_lib-premium-hook.sh <<'IMP'
IMPOSTOR_PREMIUM_LOADED=1
IMP
    touch README.md
    git add README.md .claude >/dev/null 2>&1
    git commit -q -m init >/dev/null 2>&1
  )
  echo "$sb"
}

# Source $lib from a stream (so BASH_SOURCE cannot locate its directory),
# with cwd inside the impostor repo, then run $probe. Echoes the probe output.
run_from_impostor() {
  local lib="$1" probe="$2" repo="$3"
  ( cd "$repo" || exit 1
    bash -c ". /dev/stdin; $probe" < "$HOOKS_DIR/$lib" 2>/dev/null
  )
}

# ---------------------------------------------------------------------------
# The nine #1033 sites, grouped by the lib that owns them. Each case asserts
# that NO impostor tripwire is set after the loader runs from inside a
# non-fork repo.
#
# Note these assert on the TRIPWIRE, not on whether loading succeeded.
# Refusing to load at all is a correct outcome here (the caller then degrades
# per its own contract); loading the IMPOSTOR is the bug.
# ---------------------------------------------------------------------------

assert_no_impostor() {
  local label="$1" lib="$2" probe="$3"
  local repo out
  repo=$(make_impostor_repo)
  out=$(run_from_impostor "$lib" "$probe" "$repo")
  rm -rf "$repo"
  case "$out" in
    *IMPOSTOR*) bad "$label" "loaded the impostor lib from the cwd's repo (got: $out)" ;;
    *)          ok  "$label" ;;
  esac
}

assert_no_impostor "#1033: _lib-tracker.sh config-lib loader refuses a non-fork repo" \
  "_lib-tracker.sh" \
  '_tracker_load_config_lib >/dev/null 2>&1; [ -n "${IMPOSTOR_CONFIG_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-tracker.sh portfolio-lib loader refuses a non-fork repo" \
  "_lib-tracker.sh" \
  '_tracker_load_portfolio_lib >/dev/null 2>&1; [ -n "${IMPOSTOR_PORTFOLIO_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-audit-history.sh refuses a non-fork repo" \
  "_lib-audit-history.sh" \
  '[ -n "${IMPOSTOR_CONFIG_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-extract-pr.sh refuses a non-fork repo" \
  "_lib-extract-pr.sh" \
  '[ -n "${IMPOSTOR_TRACKER_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-fresh-fork.sh refuses a non-fork repo" \
  "_lib-fresh-fork.sh" \
  '[ -n "${IMPOSTOR_CONFIG_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-onboarding-depth-mode.sh refuses a non-fork repo" \
  "_lib-onboarding-depth-mode.sh" \
  '[ -n "${IMPOSTOR_OPS_ROOT_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-onboarding-glossary-seen.sh refuses a non-fork repo" \
  "_lib-onboarding-glossary-seen.sh" \
  '[ -n "${IMPOSTOR_OPS_ROOT_LOADED:-}" ] && echo IMPOSTOR'

assert_no_impostor "#1033: _lib-project-board.sh refuses a non-fork repo" \
  "_lib-project-board.sh" \
  '[ -n "${IMPOSTOR_OPS_ROOT_LOADED:-}" ] && echo IMPOSTOR'

# _lib-premium-hook.sh is the odd one out: its fallback resolves the lib's OWN
# directory rather than sourcing a sibling, so there is no tripwire variable to
# catch. The equivalent assertion is that the resolved directory must not point
# into the cwd's repo. Probed via the returned path instead of a load side
# effect — same defect, different observable.
#
# This case was MISSING from the first draft of this file, which covered 8 of
# the 9 sites while the commit message claimed all of them. Left here as the
# ninth precisely because an uncovered site is indistinguishable from a fixed
# one in a green test run.
# Compare against `git rev-parse --show-toplevel`, NOT against $PWD. On macOS
# mktemp -d hands back /var/folders/... while git resolves the same location to
# /private/var/folders/... — a $PWD comparison silently never matches, and the
# case reports PASS while the lib is in fact loading from the impostor. That is
# how the first version of this case was written, and it produced a green result
# for a genuinely vulnerable site. A lone PASS among failing siblings in a RED
# phase is a signal to check the probe, not to celebrate.
assert_no_impostor "#1033: _lib-premium-hook.sh refuses a non-fork repo" \
  "_lib-premium-hook.sh" \
  '_top=$(git rev-parse --show-toplevel 2>/dev/null); _d=$(_premium_hook_dir 2>/dev/null);
   [ -n "$_top" ] && case "$_d" in "$_top"/*|"$_top") echo IMPOSTOR ;; esac'

# ---------------------------------------------------------------------------
# MUST-NOT-REGRESS: the anchor check must not break the legitimate fallback.
# A genuine apexyard fork (anchored by .apexyard-fork) must still resolve, or
# the #1028 zsh fix is undone and tracker_review_submit silently stops
# posting again — the exact failure #1028 existed to repair.
# ---------------------------------------------------------------------------

make_real_fork() {
  local sb; sb=$(mktemp -d)
  ( cd "$sb" || exit 1
    git init -q; git config user.email t@e.com; git config user.name t
    touch .apexyard-fork
    mkdir -p .claude/hooks
    cp "$HOOKS_DIR/_lib-read-config.sh"      .claude/hooks/
    cp "$HOOKS_DIR/_lib-portfolio-paths.sh"  .claude/hooks/
    cp "$HOOKS_DIR/_lib-ops-root.sh"         .claude/hooks/
    cp "$HOOKS_DIR/../project-config.defaults.json" .claude/ 2>/dev/null || true
    git add README.md .claude >/dev/null 2>&1; git commit -q -m init >/dev/null 2>&1
  )
  echo "$sb"
}

assert_loads_in_real_fork() {
  local label="$1" lib="$2" probe="$3"
  local repo out
  repo=$(make_real_fork)
  cp "$HOOKS_DIR/$lib" "$repo/.claude/hooks/" 2>/dev/null || true
  out=$( cd "$repo" || exit 1
         bash -c ". /dev/stdin; $probe" < "$HOOKS_DIR/$lib" 2>/dev/null )
  rm -rf "$repo"
  if [ "$out" = "OK" ]; then ok "$label"; else bad "$label" "legitimate fork fallback broke (got: '$out')"; fi
}

assert_loads_in_real_fork "#1033 guard: real fork (.apexyard-fork) still resolves the config lib" \
  "_lib-tracker.sh" \
  '_tracker_load_config_lib >/dev/null 2>&1 && command -v config_get_or >/dev/null 2>&1 && echo OK'

assert_loads_in_real_fork "#1033 guard: real fork still resolves the portfolio lib" \
  "_lib-tracker.sh" \
  '_tracker_load_portfolio_lib >/dev/null 2>&1 && command -v portfolio_registry >/dev/null 2>&1 && echo OK'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_lib_self_location_anchor.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases: $FAILED_CASES" >&2
  exit 1
fi
exit 0

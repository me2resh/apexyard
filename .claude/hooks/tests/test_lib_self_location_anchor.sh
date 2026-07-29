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

# $1 = layout: "v2" (.apexyard-fork marker) or "v1" (onboarding.yaml +
# apexyard.projects.yaml pair). Both anchors must work — a v1-only or v2-only
# guard silently breaks every fallback on the other layout.
make_real_fork() {
  local layout="${1:-v2}"
  local sb; sb=$(mktemp -d)
  ( cd "$sb" || exit 1
    git init -q; git config user.email t@e.com; git config user.name t
    if [ "$layout" = "v1" ]; then
      touch onboarding.yaml
      printf 'version: 1\nprojects: []\n' > apexyard.projects.yaml
    else
      touch .apexyard-fork
    fi
    mkdir -p .claude/hooks
    # Every lib a guarded site might source, plus the sites themselves.
    for l in _lib-read-config.sh _lib-portfolio-paths.sh _lib-ops-root.sh \
             _lib-tracker.sh _lib-audit-history.sh _lib-extract-pr.sh \
             _lib-fresh-fork.sh _lib-onboarding-depth-mode.sh \
             _lib-onboarding-glossary-seen.sh _lib-premium-hook.sh \
             _lib-project-board.sh; do
      [ -f "$HOOKS_DIR/$l" ] && cp "$HOOKS_DIR/$l" .claude/hooks/
    done
    cp "$HOOKS_DIR/../project-config.defaults.json" .claude/ 2>/dev/null || true
    # README must EXIST before it is staged. The first version of this fixture
    # staged a file it never created, so `git add` and `git commit` both failed
    # silently — the repo was uncommitted and the fixture only worked by
    # accident. Same latent-fixture class as the impostor gap fixed earlier.
    printf 'fixture\n' > README.md
    git add README.md .claude >/dev/null 2>&1
    [ "$layout" = "v1" ] && git add onboarding.yaml apexyard.projects.yaml >/dev/null 2>&1
    [ "$layout" = "v2" ] && git add .apexyard-fork >/dev/null 2>&1
    git commit -q -m init >/dev/null 2>&1
  )
  echo "$sb"
}

# POSITIVE coverage — the half the first version of this file was missing.
#
# The impostor cases above pass whenever a site refuses to load AT ALL, so an
# over-strict anchor ships green through every one of them. Rex demonstrated
# this on PR #1061 by mutation: breaking _lib-project-board.sh's anchor so it
# could never resolve left the suite 11/11. These cases close that, for all
# nine sites and on BOTH fork layouts, so an anchor that is too strict fails
# just as loudly as one that is too loose.
assert_resolves_in_fork() {
  local label="$1" lib="$2" probe="$3" layout="$4"
  local repo out
  repo=$(make_real_fork "$layout")
  out=$( cd "$repo" || exit 1
         bash -c ". /dev/stdin; $probe" < "$HOOKS_DIR/$lib" 2>/dev/null )
  rm -rf "$repo"
  if [ "$out" = "OK" ]; then ok "$label"; else bad "$label" "legitimate fork ($layout) failed to resolve (got: '$out')"; fi
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

for LAYOUT in v2 v1; do
  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-tracker.sh resolves the config lib" \
    "_lib-tracker.sh" \
    '_tracker_load_config_lib >/dev/null 2>&1 && command -v config_get_or >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-tracker.sh resolves the portfolio lib" \
    "_lib-tracker.sh" \
    '_tracker_load_portfolio_lib >/dev/null 2>&1 && command -v portfolio_registry >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-audit-history.sh resolves the config lib" \
    "_lib-audit-history.sh" \
    'command -v config_get_or >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-fresh-fork.sh resolves the config lib" \
    "_lib-fresh-fork.sh" \
    'command -v config_get_or >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-extract-pr.sh resolves the tracker lib" \
    "_lib-extract-pr.sh" \
    'command -v tracker_view >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-onboarding-depth-mode.sh resolves the ops-root lib" \
    "_lib-onboarding-depth-mode.sh" \
    'command -v resolve_ops_root >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-onboarding-glossary-seen.sh resolves the ops-root lib" \
    "_lib-onboarding-glossary-seen.sh" \
    'command -v resolve_ops_root >/dev/null 2>&1 && echo OK' "$LAYOUT"

  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-project-board.sh resolves the ops-root lib" \
    "_lib-project-board.sh" \
    'command -v resolve_ops_root >/dev/null 2>&1 && echo OK' "$LAYOUT"

  # premium-hook resolves its OWN dir, so assert the resolved path lands inside
  # the fork rather than checking for a loaded function.
  assert_resolves_in_fork "#1033 guard [$LAYOUT]: _lib-premium-hook.sh resolves its own dir inside the fork" \
    "_lib-premium-hook.sh" \
    '_top=$(git rev-parse --show-toplevel 2>/dev/null); _d=$(_premium_hook_dir 2>/dev/null);
     [ -n "$_d" ] && case "$_d" in "$_top"/*) echo OK ;; esac' "$LAYOUT"
done

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

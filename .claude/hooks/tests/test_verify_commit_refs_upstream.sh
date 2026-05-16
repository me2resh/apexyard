#!/bin/bash
# Tests for verify-commit-refs.sh upstream awareness (me2resh/apexyard#207)
# and the existing origin-only behavior it must preserve.
#
# Coverage matrix:
#   - bare #N exists in origin → pass (regression)
#   - bare #N missing in origin but present in upstream → pass (NEW)
#   - bare #N missing in both → block (regression)
#   - bare #N exists in origin, upstream not configured → pass (no-regression)
#   - cross-repo notation (owner/repo#N) → no auto-extracted #N → pass
#   - bare #N is CLOSED in upstream → still passes (WARN, never block on closed)
#   - fork without `upstream` remote configured → identical to origin-only
#
# Each case:
#   - builds an isolated sandbox with the hook + mock gh
#   - configures a `git remote upstream` when the case needs one
#   - pipes a synthetic PreToolUse JSON blob with `git commit -m "<msg>"`
#   - asserts exit code + stderr contents

set -u

HOOK_SRC="$(cd "$(dirname "$0")/.." && pwd)/verify-commit-refs.sh"
# shellcheck source=_lib-mock-gh.sh
source "$(cd "$(dirname "$0")" && pwd)/_lib-mock-gh.sh"
if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

# Build a sandbox shaped like a fork: origin = fork-org/apexyard, optional
# upstream = me2resh/apexyard. The `tracker_repo` config key isn't set, so
# the hook falls back to parsing origin (matches real-world fork layout).
make_sandbox_fork() {
  local with_upstream="$1"
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    git remote add origin git@github.com:fork-org/apexyard.git
    if [ "$with_upstream" = "yes" ]; then
      git remote add upstream git@github.com:me2resh/apexyard.git
    fi
    git checkout -q -b fix/#207-test 2>/dev/null || git checkout -q -B fix/#207-test
    touch README.md
    git add README.md
    git commit -q -m "init"
  )
  echo "$sb"
}

# Run the hook with a synthetic `git commit -m "<msg>"` command and assert
# the exit code + (optional) stderr regex. Existence-config callback lets
# each case set its own mock-gh entries before the hook runs.
#
#   run_case <label> <with_upstream:yes|no> <commit_msg> <want_rc> <stderr_regex> [<existence_setup>]
run_case() {
  local label="$1" with_upstream="$2" commit_msg="$3" want_rc="$4" want_stderr_regex="$5" exist_setup="${6:-}"
  local sb; sb=$(make_sandbox_fork "$with_upstream")
  mock_gh_install "$sb"
  if [ -n "$exist_setup" ]; then
    eval "$exist_setup"
  fi
  # commit_msg uses `\n` for newlines in the test source for readability;
  # convert them to real newlines so the parsed -m argument matches the way
  # bash sees a real multi-line commit (no `\b` issue against a literal `\n`).
  local cmd_msg; cmd_msg=$(printf '%b' "$commit_msg")
  local cmd; cmd=$(printf 'git commit -m "%s"' "$cmd_msg")
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash "$HOOK_SRC" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc (stderr: ${got_stderr:0:300})" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "; return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---- Cases --------------------------------------------------------------

# Regression: bare #N that exists in origin passes, no upstream consulted.
run_case "bare #N in origin, no upstream remote → pass" \
  "no" \
  "fix: something\n\nCloses #42" \
  0 "" \
  ''

# NEW: bare #N missing in origin, present in upstream → pass.
run_case "bare #N in upstream only → pass (the #207 fix)" \
  "yes" \
  "fix: upstream issue\n\nCloses #150" \
  0 "" \
  'mock_gh_set_repo_existence "$sb" 150 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 150 me2resh/apexyard yes'

# Regression: missing in both → block.
run_case "bare #N missing in both → block" \
  "yes" \
  "fix: phantom\n\nCloses #99999" \
  2 "doesnot exist|do not exist" \
  'mock_gh_set_repo_existence "$sb" 99999 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 99999 me2resh/apexyard no'

# Regression: bare #N in origin, no upstream configured → pass (no regression).
run_case "bare #N in origin, upstream unconfigured → pass" \
  "no" \
  "feat: do thing\n\nCloses #5" \
  0 "" \
  ''

# Cross-repo notation (`owner/repo#N`) — the existing REFS regex requires
# `#` immediately after the closing keyword + whitespace, so `me2resh/apexyard#150`
# is not picked up as a #N reference at all. This is unchanged behavior;
# adding the test pins it so future regex changes don't break backwards-compat.
run_case "cross-repo notation owner/repo#N → no #N extracted → pass" \
  "yes" \
  "fix: cross-repo\n\nCloses me2resh/apexyard#150" \
  0 "" \
  ''

# Closed-but-existing in upstream is still allowed through (WARN, not BLOCK).
# Existing rule: closed-issue refs are warned at commit time; the PR-create
# hook is the right place to BLOCK closed-issue refs. The fix preserves that.
run_case "bare #N CLOSED in upstream → pass with WARN" \
  "yes" \
  "fix: closed upstream\n\nRefs #777" \
  0 "WARN" \
  'mock_gh_set_repo_existence "$sb" 777 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 777 me2resh/apexyard yes
   mock_gh_set_state "$sb" 777 CLOSED'

# When origin and upstream both resolve to the same repo (e.g. running INSIDE
# the framework itself), the hook should not double-query. We can't observe
# the query count directly, but we can assert the hook passes when the issue
# exists in origin — exercising the "skip upstream because UPSTREAM_REPO ==
# TRACKER_REPO" branch.
run_case "upstream == origin → no double-check, still passes when issue in origin" \
  "no" \
  "fix: same repo\n\nCloses #1" \
  0 "" \
  ''

# Network failure equivalent: gh returns nothing for any repo (no existence
# entries → falls through to default-exists-everywhere). But we can flip into
# per-repo mode with "no" entries to simulate network failure. Result must
# be: block (treat as not found) — matches existing fail-closed behavior.
run_case "gh returns nothing in both → block (fail-closed)" \
  "yes" \
  "fix: ghost\n\nFixes #321" \
  2 "do not exist" \
  'mock_gh_set_repo_existence "$sb" 321 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 321 me2resh/apexyard no'

# Short-circuit: when origin says yes, upstream should NOT be consulted.
# Verified indirectly by setting upstream to "no" and origin to "yes" —
# if the hook checked upstream too, this case would still pass; if it
# short-circuits on origin success, this case also passes. Both behaviors
# yield the same result, so this case is mostly documentation.
run_case "origin yes, upstream no → pass (short-circuit on origin)" \
  "yes" \
  "fix: in origin\n\nCloses #7" \
  0 "" \
  'mock_gh_set_repo_existence "$sb" 7 fork-org/apexyard yes
   mock_gh_set_repo_existence "$sb" 7 me2resh/apexyard no'

# ---- Embedded double quotes in commit message — me2resh/apexyard#227 ----
# Pre-227 the sed-based -m extractor's `"([^"]*)"` regex truncated the
# commit message at the FIRST embedded `"`, so any `Closes #N` reference
# that lived past the first internal `"` was invisible to the hook.
# Result: a fabricated #N in the back half slipped through, and a real
# #N pre-quote got verified but the rest weren't. Post-fix the extractor
# is greedy + anchored on next-flag-or-EOS.

# Embedded quote followed by a real #N in origin → must extract #N → pass.
run_case "commit msg with embedded quote + valid Closes #N after → pass" \
  "no" \
  'fix: handle "admin notice" string\n\nThe notice said "do the thing".\n\nCloses #42' \
  0 "" \
  ''

# Embedded quote followed by a phantom #N → must extract #N → block.
# Pre-fix: the regex would truncate at the first `"` and #99999 (post-quote)
# would never be extracted → false PASS. Post-fix: full message scans, #99999
# is found, the gh lookup fails on both repos, hook blocks.
run_case "commit msg with embedded quote + phantom Closes #N after → block" \
  "yes" \
  'fix: handle "admin notice" string\n\nDescribed "current state" flow.\n\nCloses #99999' \
  2 "do not exist" \
  'mock_gh_set_repo_existence "$sb" 99999 fork-org/apexyard no
   mock_gh_set_repo_existence "$sb" 99999 me2resh/apexyard no'

# Multiple embedded quotes — pre-fix the second `"` would end the truncated
# value early. Post-fix all #N references are extracted and verified.
run_case "commit msg with multiple embedded quotes + Closes #N → pass" \
  "no" \
  'feat: add "X" and "Y" and "Z" tags\n\nAll three are "important".\n\nCloses #5' \
  0 "" \
  ''

# ---- Summary ------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0

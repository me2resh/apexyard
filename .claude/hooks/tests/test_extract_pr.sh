#!/bin/bash
# Tests for extract_pr_number() in _lib-extract-pr.sh — regression suite for
# bug #568 (stderr redirect `2>&1` digit contamination when PR arg is a shell
# variable) plus happy-path and gh-api-shape coverage.
#
# Cases:
#   1. `gh pr merge 42 --squash`                              → 42
#   2. `gh pr merge 42 --squash 2>&1 | tail -5`              → 42 (NOT 2)
#   3. `gh pr merge $pr --squash 2>&1`                       → empty (unexpanded var)
#   4. `gh api repos/o/r/pulls/42/merge -X PUT`              → 42
#   5. `gh api .../pulls/7/merge 2>&1`                       → 7  (NOT 2)
#   6. `gh pr merge 123 --repo foo/bar --squash 2>&1 | tail` → 123 (NOT 2)
#   7. `gh pr merge ${PR_NUMBER} --squash`                   → empty (unexpanded braces)
#   8. `gh pr merge 42 2>err.log`                            → 42 (NOT 2)
#   9. `gh pr merge 42 &>out.log`                            → 42
#  10. `gh pr merge 42 >>out.log`                            → 42
#
# Note: cases where pr="" fall through to the `gh pr view` fallback inside the
# real library. In these tests we only source the library function and do NOT
# mock `gh`, so the fallback will also return empty (no real GitHub API call).
# That is intentional — we are testing the string-parsing layer only.
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

LIB_SRC="$(cd "$(dirname "$0")/.." && pwd)/_lib-extract-pr.sh"
if [ ! -f "$LIB_SRC" ]; then
  echo "FAIL: lib not found at $LIB_SRC" >&2
  exit 1
fi

# Source the library. We need to shim `gh` so that the step-3 fallback
# (`gh pr view …`) returns empty rather than making a real network call.
# Drop a minimal shim on PATH before sourcing.
SHIM_DIR=$(mktemp -d)
cat > "$SHIM_DIR/gh" <<'GHEOF'
#!/bin/bash
# Shim: return empty for all calls — test only cares about string parsing.
exit 0
GHEOF
chmod +x "$SHIM_DIR/gh"
export PATH="$SHIM_DIR:$PATH"

# shellcheck source=/dev/null
. "$LIB_SRC"

PASS=0
FAIL=0
FAILED_CASES=""

assert_pr() {
  local label="$1" cmd="$2" want="$3"
  local got
  got=$(extract_pr_number "$cmd")
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]: cmd=[$cmd]  want=[$want]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
}

# --- Happy path: literal PR number, no redirections ----------------------

assert_pr "plain merge 42" \
  "gh pr merge 42 --squash" \
  "42"

assert_pr "merge with --repo flag" \
  "gh pr merge 99 --repo me2resh/apexyard --squash" \
  "99"

# --- Bug #568: redirect tokens must not donate digits --------------------

# Core repro: 2>&1 before a pipe — the old code returned 2 here.
assert_pr "merge 42 with 2>&1 pipe (bug #568 repro)" \
  "gh pr merge 42 --squash 2>&1 | tail -5" \
  "42"

# Unexpanded shell variable + 2>&1: old code returned 2, correct is empty.
assert_pr "merge \$pr with 2>&1 → empty (var unexpanded)" \
  'gh pr merge $pr --squash 2>&1' \
  ""

# Curly-brace unexpanded variable.
assert_pr "merge \${PR_NUMBER} → empty (var unexpanded)" \
  'gh pr merge ${PR_NUMBER} --squash' \
  ""

# Append redirect (>>).
assert_pr "merge 42 with >> redirect" \
  "gh pr merge 42 >>out.log" \
  "42"

# Overwrite redirect (>).
assert_pr "merge 42 with > redirect" \
  "gh pr merge 42 >out.log" \
  "42"

# Combined Bash &> redirect.
assert_pr "merge 42 with &> redirect" \
  "gh pr merge 42 &>out.log" \
  "42"

# fd-specific write redirect.
assert_pr "merge 42 with 2>err.log" \
  "gh pr merge 42 2>err.log" \
  "42"

# All together: repo flag, redirect, pipe.
assert_pr "merge 123 with --repo + 2>&1 + pipe" \
  "gh pr merge 123 --repo foo/bar --squash 2>&1 | tail" \
  "123"

# --- gh api URL path shape -----------------------------------------------

assert_pr "gh api pulls/42/merge" \
  "gh api repos/o/r/pulls/42/merge -X PUT" \
  "42"

# gh api with 2>&1 — the 2 must NOT win; the URL path number must.
assert_pr "gh api pulls/7/merge with 2>&1" \
  "gh api repos/me2resh/apexyard/pulls/7/merge -X PUT 2>&1" \
  "7"

# --- Edge cases ----------------------------------------------------------

# No PR number at all → empty (triggers gh pr view fallback, returns empty in test).
assert_pr "merge with no number → empty" \
  "gh pr merge --squash" \
  ""

# Unrelated command → empty.
assert_pr "gh pr view is not a merge command" \
  "gh pr view 42" \
  ""

# --- #643: merge_command_uses_variable (variable-substituted merge detection) ---

assert_var() {
  local label="$1" cmd="$2" want="$3"   # want: "yes" (uses var) | "no"
  local got="no"
  merge_command_uses_variable "$cmd" && got="yes"
  if [ "$got" = "$want" ]; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]: cmd=[$cmd]  want=[$want]  got=[$got]" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
  fi
}

# Variable PR arg → yes
assert_var "var PR \$PR"            'gh pr merge $PR --repo me2resh/apexyard --squash' "yes"
assert_var "var PR \${PR_NUMBER}"  'gh pr merge ${PR_NUMBER} --squash'                "yes"
# Variable --repo value → yes (even with a literal PR number)
assert_var "var repo \$REPO"       'gh pr merge 378 --repo $REPO --squash'            "yes"
assert_var "var repo \${REPO}"     'gh pr merge 378 --repo ${REPO} --squash'          "yes"
# Quoted variable forms → yes (the common shape agents/operators write)
assert_var "quoted var PR \"\$PR\""    'gh pr merge "$PR" --repo me2resh/apexyard'    "yes"
assert_var "quoted var repo \"\$REPO\"" 'gh pr merge 378 --repo "$REPO" --squash'      "yes"
# Both literal → no
assert_var "literal PR + repo"     'gh pr merge 378 --repo me2resh/apexyard --squash' "no"
assert_var "literal PR no repo"    'gh pr merge 42 --squash'                          "no"
# Redirections must not be mistaken for a variable PR arg
assert_var "literal + 2>&1 pipe"   'gh pr merge 42 --squash 2>&1 | tail -5'           "no"
# gh api shape (literal path) → no
assert_var "gh api literal path"   'gh api repos/o/r/pulls/42/merge -X PUT'           "no"

# --- Cleanup -------------------------------------------------------------
rm -rf "$SHIM_DIR"

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0

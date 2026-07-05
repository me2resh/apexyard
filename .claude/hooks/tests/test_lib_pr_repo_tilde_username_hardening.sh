#!/bin/bash
# Regression test — LOW hardening finding from Hakim's security review of
# PR #792 (apexyard#791 fix): the `~user` username allowlist check in
# `_pr_repo_expand_tilde` (_lib-pr-repo.sh) used to be a PER-LINE grep,
# `grep -qE '^[A-Za-z0-9._-]+$'`, which matches per line rather than across
# the whole string. A multi-line `$user` whose FIRST line looks like a valid
# username passes that check even though later lines carry arbitrary text —
# and the validated (but still multi-line) value was then handed straight to
# `eval echo "~${user}"`.
#
# THE BUG (in isolation)
# -----------------------
# Not reachable through the current sole caller, `pr_cmd_cd_target`: its sed
# extraction is single-line by construction and is further piped through
# `head -1`, so `$user` can never carry an embedded newline when reached via
# that path. But `_pr_repo_expand_tilde` is a shared, standalone lib
# function — a future caller that skips that sanitization (or calls the
# function directly with attacker-influenced input) would reach `eval` with
# a multi-line, per-line-only-validated `$user`, which is a latent
# command-injection surface in a trust-chain hook (`.claude/hooks/**`).
#
# THE FIX
# -------
# Swap the per-line `grep -qE '^…$'` for bash's `[[ "$user" =~ ^…$ ]]`, which
# anchors against the WHOLE string (`^` / `$` bind to start/end of the full
# value, not per line) — a multi-line value now fails the check outright
# regardless of what its first line looks like, and `eval` is never reached.
#
# THIS TEST
# ---------
# Sources _lib-pr-repo.sh directly and calls the internal
# `_pr_repo_expand_tilde` function with a hostile multi-line `~user` value
# whose first line is a valid-looking username and whose second line is a
# shell command that would create a sentinel file if it ever reached `eval`.
# Asserts (a) the sentinel file is never created, and (b) the function
# degrades gracefully — returns the original string unchanged, exactly as it
# does for any other unresolvable/rejected `~user` form.
#
# Exit 0 if all cases pass; exit 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB_PR_REPO="$SRC_ROOT/.claude/hooks/_lib-pr-repo.sh"

if [ ! -f "$LIB_PR_REPO" ]; then
  echo "FAIL: lib not found at $LIB_PR_REPO" >&2
  exit 1
fi

# shellcheck source=/dev/null
. "$LIB_PR_REPO"

PASS=0
FAIL=0
FAILED_CASES=""

# assert_no_eval_reach label path_value
#   Calls _pr_repo_expand_tilde with a $1-shaped path whose embedded second
#   line would touch a sentinel file if `eval` ever executed it. Asserts the
#   sentinel is never created AND the function returns the input unchanged
#   (the documented graceful-fallback behaviour for a rejected token).
assert_no_eval_reach() {
  local label="$1" path_value="$2"
  local sentinel got
  sentinel=$(mktemp -u /tmp/apexyard-test-tilde-hardening.XXXXXX)
  rm -f "$sentinel"

  # Rebuild path_value with the real sentinel path substituted in for the
  # __SENTINEL__ placeholder (keeps callers readable).
  path_value="${path_value//__SENTINEL__/$sentinel}"

  got=$(_pr_repo_expand_tilde "$path_value")
  local rc=$?

  if [ -e "$sentinel" ]; then
    echo "FAIL [$label]: sentinel file WAS created — eval executed injected content!" >&2
    rm -f "$sentinel"
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  rm -f "$sentinel"

  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: function exited non-zero ($rc)" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi

  if [ "$got" != "$path_value" ]; then
    echo "FAIL [$label]: want unchanged passthrough, got: $got" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi

  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# ---------------------------------------------------------------------------
# The reported hardening gap: first line of $user looks like a valid
# username, second line is an injected shell command.
# ---------------------------------------------------------------------------

MULTILINE_USER=$'validuser\ntouch __SENTINEL__'
assert_no_eval_reach \
  "multi-line ~user (valid-looking first line + injected 2nd line) does NOT reach eval" \
  "~${MULTILINE_USER}"

MULTILINE_USER_WITH_TAIL=$'validuser\ntouch __SENTINEL__'
assert_no_eval_reach \
  "multi-line ~user/tail-path variant does NOT reach eval" \
  "~${MULTILINE_USER_WITH_TAIL}/Projects/foo"

# ---------------------------------------------------------------------------
# Sanity: legitimate single-line ~user forms still behave as documented
# (this is a behaviour-preservation check, not a new requirement — confirms
# the hardening didn't regress the happy path).
# ---------------------------------------------------------------------------

result=$(_pr_repo_expand_tilde "~root")
if [ -n "$result" ] && [ "$result" != "~root" ]; then
  echo "PASS [~root (single-line, real user) still resolves via eval]"
  PASS=$((PASS+1))
else
  echo "FAIL [~root (single-line, real user) still resolves via eval]: got '$result'" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}root-resolves "
fi

result=$(_pr_repo_expand_tilde "~zzznosuchuser999/x")
if [ "$result" = "~zzznosuchuser999/x" ]; then
  echo "PASS [~nosuchuser (single-line, unknown user) degrades unchanged]"
  PASS=$((PASS+1))
else
  echo "FAIL [~nosuchuser (single-line, unknown user) degrades unchanged]: got '$result'" >&2
  FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}nosuchuser-passthrough "
fi

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0

#!/bin/bash
# Tests for .claude/hooks/_lib-merge-behind.sh (me2resh/apexyard#1386, B1)
#
# is_pr_behind_base reads "behind" from the compare API's behind_by field,
# not from the forge's mergeStateStatus field. GitHub only reports
# mergeStateStatus=BEHIND when the base branch's ruleset has
# strict_required_status_checks_policy=true — off by default, and off in
# this repo's own dev ruleset. A PR that is genuinely behind an unprotected
# base reports BLOCKED, CLEAN, or UNKNOWN for mergeStateStatus instead, so
# this library never reads that field at all.
#
# Covers:
#   1. behind_by > 0 -> "true"
#   2. behind_by == 0 -> "false"
#   3. gh api call fails (network/auth) -> "unknown", exit 0, no crash
#   4. non-numeric / empty behind_by -> "unknown"
#   5. missing argument (repo, base, or head) -> "unknown", no gh call made
#   6. large behind_by (19, matching #1386's own reported evidence) -> "true"
#
# Exit 0 if all pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-merge-behind.sh"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  FAIL: %s: %s\n" "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}\n  - $1"; }

make_sandbox_with_gh() {
  # $1: the value the mock `gh api .../compare/...` call should print for
  #     `-q '.behind_by'`, or "FAIL" to make the mock exit non-zero
  #     (simulating a network/auth failure).
  local behind_by="$1"
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/bin"
  if [ "$behind_by" = "FAIL" ]; then
    cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
  else
    cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api "*"compare/"*) echo "$behind_by" ;;
  *) ;;
esac
exit 0
EOF
  fi
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

# ---------------------------------------------------------------------------
# Case 1: behind_by > 0 -> "true"
# ---------------------------------------------------------------------------
sb=$(make_sandbox_with_gh 5)
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rm -rf "$sb"
[ "$got" = "true" ] && mark_pass "behind_by=5 -> true" \
                     || mark_fail "behind_by=5" "got '$got'"

# ---------------------------------------------------------------------------
# Case 2: behind_by == 0 -> "false"
# ---------------------------------------------------------------------------
sb=$(make_sandbox_with_gh 0)
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rm -rf "$sb"
[ "$got" = "false" ] && mark_pass "behind_by=0 -> false" \
                      || mark_fail "behind_by=0" "got '$got'"

# ---------------------------------------------------------------------------
# Case 3: gh api call fails (network/auth) -> "unknown", exit 0
# ---------------------------------------------------------------------------
sb=$(make_sandbox_with_gh FAIL)
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rc=$?
rm -rf "$sb"
if [ "$got" = "unknown" ] && [ "$rc" = "0" ]; then
  mark_pass "gh api failure -> unknown, exit 0 (fail-soft, never blocks)"
else
  mark_fail "gh api failure" "got '$got' rc=$rc"
fi

# ---------------------------------------------------------------------------
# Case 4: non-numeric / empty behind_by -> "unknown"
# ---------------------------------------------------------------------------
sb=$(make_sandbox_with_gh "")
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rm -rf "$sb"
[ "$got" = "unknown" ] && mark_pass "empty behind_by -> unknown" \
                        || mark_fail "empty behind_by" "got '$got'"

sb=$(make_sandbox_with_gh "null")
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rm -rf "$sb"
[ "$got" = "unknown" ] && mark_pass "non-numeric behind_by ('null') -> unknown" \
                        || mark_fail "non-numeric behind_by" "got '$got'"

# ---------------------------------------------------------------------------
# Case 5: missing argument -> "unknown", and no gh call is made at all
# ---------------------------------------------------------------------------
sb=$(mktemp -d)
mkdir -p "$sb/bin"
cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
echo "UNEXPECTED_GH_CALL: $*" >> "$SANDBOX_GH_LOG"
exit 1
EOF
chmod +x "$sb/bin/gh"
got=$(SANDBOX_GH_LOG="$sb/gh.log" PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base '' dev abc1234")
CALLED=$([ -f "$sb/gh.log" ] && echo "yes" || echo "no")
rm -rf "$sb"
if [ "$got" = "unknown" ] && [ "$CALLED" = "no" ]; then
  mark_pass "missing repo argument -> unknown, no gh call made"
else
  mark_fail "missing repo argument" "got '$got' gh_called=$CALLED"
fi

# ---------------------------------------------------------------------------
# Case 6: large behind_by (matches #1386's own reported evidence — PRs 8
# and 19 commits behind) -> "true"
# ---------------------------------------------------------------------------
sb=$(make_sandbox_with_gh 19)
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rm -rf "$sb"
[ "$got" = "true" ] && mark_pass "behind_by=19 (#1386's own evidence) -> true" \
                     || mark_fail "behind_by=19" "got '$got'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_lib_merge_behind.sh ====="
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "Failed cases:%b\n" "$FAILED_CASES"
  exit 1
fi
exit 0

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
#   7. gh api call prints "0" but exits non-zero -> "unknown", not "false"
#      (Hakim LOW-2, PR me2resh/apexyard#1406) — stdout alone is never
#      trusted; a non-zero exit code always wins, even over a well-formed
#      number.
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
# Case 7 (Hakim LOW-2): gh api prints "0" but exits non-zero -> "unknown"
#
# Before the fix, the function read stdout only, so a well-formed "0" on a
# failed call returned "false" — the safe-looking value on a call that did
# not actually succeed. The exit code must win over stdout.
# ---------------------------------------------------------------------------
sb=$(mktemp -d)
mkdir -p "$sb/bin"
cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"api "*"compare/"*) echo "0" ;;
  *) ;;
esac
exit 1
EOF
chmod +x "$sb/bin/gh"
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; is_pr_behind_base me2resh/apexyard dev abc1234")
rm -rf "$sb"
[ "$got" = "unknown" ] && mark_pass "gh api prints '0' but exits non-zero -> unknown" \
                        || mark_fail "gh api prints '0' but exits non-zero" "got '$got'"

# ===========================================================================
# rex_approval_carries_over (me2resh/apexyard#1437)
#
# Builds real git history in a throwaway repo so the merge-commit shape
# (parent count, parent[0] identity, remerge-diff cleanliness) is genuine,
# not simulated. Fail-before: these cases exercise behaviour that does not
# exist on dev — before this PR, this function is undefined.
# ===========================================================================

make_git_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "Test"
  echo "$d"
}

if command -v git >/dev/null 2>&1; then

  # -------------------------------------------------------------------------
  # Case 8: clean base merge, parent[0] == old_sha, empty remerge-diff -> true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; git -C "$repo" add pr.txt; git -C "$repo" commit -q -m "pr work"
  OLD_SHA=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  echo more-base > "$repo/base2.txt"; git -C "$repo" add base2.txt; git -C "$repo" commit -q -m "base moves on"
  git -C "$repo" checkout -q pr-branch
  git -C "$repo" merge -q --no-ff main -m "merge main into pr-branch"
  NEW_SHA=$(git -C "$repo" rev-parse HEAD)
  got=$(cd "$repo" && bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $OLD_SHA $NEW_SHA")
  rm -rf "$repo"
  [ "$got" = "true" ] && mark_pass "clean base merge, parent[0]==old_sha, empty remerge -> true" \
                       || mark_fail "clean base merge carry-over" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 9: non-merge commit (1 parent) -> false, never true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -q -m base
  OLD_SHA=$(git -C "$repo" rev-parse HEAD)
  echo more > "$repo/more.txt"; git -C "$repo" add more.txt; git -C "$repo" commit -q -m "ordinary commit"
  NEW_SHA=$(git -C "$repo" rev-parse HEAD)
  got=$(cd "$repo" && bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $OLD_SHA $NEW_SHA")
  rm -rf "$repo"
  [ "$got" = "false" ] && mark_pass "non-merge commit (1 parent) -> false" \
                        || mark_fail "non-merge commit" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 10: octopus merge (3 parents) -> false, never true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -q -m base
  OLD_SHA=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b b1; echo b1 > "$repo/b1.txt"; git -C "$repo" add b1.txt; git -C "$repo" commit -q -m b1
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b b2; echo b2 > "$repo/b2.txt"; git -C "$repo" add b2.txt; git -C "$repo" commit -q -m b2
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff -m "octopus" b1 b2
  NEW_SHA=$(git -C "$repo" rev-parse HEAD)
  got=$(cd "$repo" && bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $OLD_SHA $NEW_SHA")
  rm -rf "$repo"
  [ "$got" = "false" ] && mark_pass "octopus merge (3 parents) -> false" \
                        || mark_fail "octopus merge" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 11: two-parent merge, but first parent is NOT old_sha -> false
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -q -m base
  UNRELATED_SHA=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; git -C "$repo" add pr.txt; git -C "$repo" commit -q -m "pr work"
  git -C "$repo" checkout -q main
  echo more-base > "$repo/base2.txt"; git -C "$repo" add base2.txt; git -C "$repo" commit -q -m "base moves on"
  git -C "$repo" checkout -q pr-branch
  git -C "$repo" merge -q --no-ff main -m "merge main into pr-branch"
  NEW_SHA=$(git -C "$repo" rev-parse HEAD)
  # OLD_SHA below is deliberately NOT this merge's first parent.
  got=$(cd "$repo" && bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $UNRELATED_SHA $NEW_SHA")
  rm -rf "$repo"
  [ "$got" = "false" ] && mark_pass "two-parent merge but parent[0] != old_sha -> false" \
                        || mark_fail "wrong parent[0]" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 12: clean two-parent merge shape, but a hand edit makes the
  # remerge-diff non-empty -> false (conflict resolution / hand edit)
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/shared.txt"; git -C "$repo" add shared.txt; git -C "$repo" commit -q -m base
  git -C "$repo" checkout -q -b pr-branch
  echo "pr change" > "$repo/shared.txt"; git -C "$repo" add shared.txt; git -C "$repo" commit -q -m "pr edits shared.txt"
  OLD_SHA=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  echo "base change" > "$repo/shared.txt"; git -C "$repo" add shared.txt; git -C "$repo" commit -q -m "base also edits shared.txt"
  git -C "$repo" checkout -q pr-branch
  git -C "$repo" merge -q --no-ff main -m "merge main into pr-branch" 2>/dev/null || true
  # Resolve the conflict by hand instead of letting git's own recursive
  # merge stand — this is exactly the "hand edit" case remerge-diff exists
  # to catch.
  echo "hand-resolved" > "$repo/shared.txt"
  git -C "$repo" add shared.txt
  git -C "$repo" commit -q -m "merge main into pr-branch" 2>/dev/null || git -C "$repo" -c core.editor=true commit -q --no-edit
  NEW_SHA=$(git -C "$repo" rev-parse HEAD)
  got=$(cd "$repo" && bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $OLD_SHA $NEW_SHA")
  rm -rf "$repo"
  [ "$got" = "false" ] && mark_pass "hand-resolved conflict -> non-empty remerge-diff -> false" \
                        || mark_fail "hand-resolved conflict" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 13: missing object (SHA that does not exist) -> unknown, never true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -q -m base
  NEW_SHA=$(git -C "$repo" rev-parse HEAD)
  got=$(cd "$repo" && bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo 0000000000000000000000000000000000000000 $NEW_SHA")
  rm -rf "$repo"
  [ "$got" = "unknown" ] && mark_pass "missing old_sha object -> unknown" \
                          || mark_fail "missing object" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 14: missing/empty arguments -> unknown
  # -------------------------------------------------------------------------
  got=$(bash -c ". '$LIB'; rex_approval_carries_over '' abc def")
  [ "$got" = "unknown" ] && mark_pass "missing repo arg -> unknown" \
                          || mark_fail "missing repo arg" "got '$got'"

else
  echo "  SKIP: git not on PATH — rex_approval_carries_over cases skipped" >&2
fi

# ===========================================================================
# merge_refresh_required (me2resh/apexyard#1437)
#
# Fail-before: this function is undefined on dev.
# ===========================================================================

make_sandbox_with_gh_script() {
  # $1: a shell snippet defining the gh mock body (case "$*" in ... esac).
  local body="$1"
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/bin"
  {
    echo '#!/bin/bash'
    echo "$body"
    echo 'exit 0'
  } > "$sb/bin/gh"
  chmod +x "$sb/bin/gh"
  echo "$sb"
}

# Case 15: no overlap at all -> skippable
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"docs/unrelated.md\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "skippable" ] && mark_pass "no file/pattern overlap -> skippable" \
                          || mark_fail "no overlap" "got '$got'"

# Case 16: base touches a file the PR also touches -> required
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/shared.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"src/shared.txt\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 ''")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "base overlaps a PR file -> required" \
                         || mark_fail "PR-file overlap" "got '$got'"

# Case 17: base touches a shared-pattern file (not a PR file) -> required
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\".claude/hooks/_lib-merge-behind.sh\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "base overlaps a shared-file pattern -> required" \
                         || mark_fail "shared-pattern overlap" "got '$got'"

# Case 18: compare API call fails -> required (fail closed)
sb=$(mktemp -d)
mkdir -p "$sb/bin"
cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt"; exit 0 ;;
  *"compare/"*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$sb/bin/gh"
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 ''")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "compare API failure -> required" \
                         || mark_fail "compare API failure" "got '$got'"

# Case 19: PR-files API call fails -> required (fail closed)
sb=$(mktemp -d)
mkdir -p "$sb/bin"
cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"pulls/1/files"*) exit 1 ;;
  *"compare/"*) echo '{"files":[]}'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$sb/bin/gh"
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 ''")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "PR-files API failure -> required" \
                         || mark_fail "PR-files API failure" "got '$got'"

# Case 20: truncated compare (>= 300 base files) -> required (fail closed)
sb=$(mktemp -d)
mkdir -p "$sb/bin"
cat > "$sb/bin/gen_files.py" <<'PYEOF'
print("{\"files\": [" + ",".join('{"filename":"f%d.txt"}' % i for i in range(300)) + "]}")
PYEOF
cat > "$sb/bin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/"*) python3 "$sb/bin/gen_files.py" 2>/dev/null || echo '{"files":[]}' ;;
esac
exit 0
EOF
chmod +x "$sb/bin/gh"
if command -v python3 >/dev/null 2>&1; then
  got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 ''")
  [ "$got" = "required" ] && mark_pass "300+ base files (truncated compare) -> required" \
                           || mark_fail "truncated compare" "got '$got'"
else
  echo "  SKIP: python3 not on PATH — truncated-compare case skipped" >&2
fi
rm -rf "$sb"

# Case 21: missing argument -> required
got=$(bash -c ". '$LIB'; merge_refresh_required '' main 1 base123 ''")
[ "$got" = "required" ] && mark_pass "missing repo arg -> required" \
                         || mark_fail "missing repo arg" "got '$got'"

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

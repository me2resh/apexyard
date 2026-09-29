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
# rex_approval_carries_over (me2resh/apexyard#1437, round-2 review)
#
# Builds real git history in a throwaway repo so the merge-commit shape
# (parent count, parent identities, merge-tree reproducibility) is genuine,
# not simulated. A GENERIC `gh` mock (make_rex_carry_gh_mock below) answers
# the forge commit/base-tip calls by reading the SAME repo's real git
# objects, so "what the forge reports" and "what git can locally verify"
# stay a single source of truth per case — except where a case deliberately
# points them at different things (the round-2 bypass regression, case B).
#
# Fail-before: this function (and its <base_branch> 4th argument, and its
# forge-verification behaviour) does not exist on dev — before this PR, the
# function is undefined; before the round-2 revision, it existed but only
# checked parent[0], never parent[1] against the forge-resolved base tip —
# case B below is the regression pin for exactly that bypass.
# ===========================================================================

make_git_repo() {
  # Sandbox blocks creating a path named ".git". Use an explicit gitdir
  # and the g() helper (or GIT_DIR/GIT_WORK_TREE) for every git call.
  local d
  d=$(mktemp -d)
  mkdir -p "$d/gitdir/objects" "$d/gitdir/refs/heads"
  printf 'ref: refs/heads/main\n' > "$d/gitdir/HEAD"
  printf '%s\n' \
    '[core]' \
    '	repositoryformatversion = 0' \
    '	filemode = true' \
    '	bare = false' \
    '	logallrefupdates = true' > "$d/gitdir/config"
  GIT_DIR="$d/gitdir" GIT_WORK_TREE="$d" git config user.email test@example.com
  GIT_DIR="$d/gitdir" GIT_WORK_TREE="$d" git config user.name "Test"
  echo "$d"
}

# g <repo> <git-args...> — run git against a make_git_repo checkout.
g() {
  local repo="$1"
  shift
  GIT_DIR="$repo/gitdir" GIT_WORK_TREE="$repo" git "$@"
}

# carry_over_in <repo> <old> <new> <base> — invoke rex_approval_carries_over
# with GIT_DIR/GIT_WORK_TREE set so the function sees a real work tree.
carry_over_in() {
  local repo="$1" old="$2" new="$3" base="$4" sb_bin="$5"
  GIT_DIR="$repo/gitdir" GIT_WORK_TREE="$repo" PATH="$sb_bin:$PATH" \
    bash -c ". '$LIB'; rex_approval_carries_over acme-org/example '$old' '$new' '$base'"
}

# make_rex_carry_gh_mock <sandbox_dir> <repo_git_dir> [<base_branch_override>]
# Writes a `gh` shim at <sandbox_dir>/bin/gh that answers BOTH forge calls
# rex_approval_carries_over makes, by reading real objects out of
# <repo_git_dir>:
#   - `... branches/<name> -q .commit.sha` -> that branch's real tip SHA
#     (via refs/heads/<name> so a tag cannot shadow)
#   - `... commits/<sha>` (no -q)          -> real parents + tree, as JSON
# <base_branch_override>, if given, is a SHA-or-name gh should report an
# error for instead of resolving (models "the tip cannot be resolved").
make_rex_carry_gh_mock() {
  local sb="$1" repo_dir="$2" unresolvable="${3:-}"
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
REPO_DIR="$repo_dir"
UNRESOLVABLE="$unresolvable"
args="\$*"
case "\$args" in
  *"/branches/"*)
    ref=\$(printf '%s' "\$args" | sed -E 's#.*branches/([^ ]+).*#\1#')
    # Minimal URL-decode for test branch names that contain '/'.
    ref=\$(printf '%s' "\$ref" | sed 's/%2[Ff]/\//g')
    if [ -n "\$UNRESOLVABLE" ] && [ "\$ref" = "\$UNRESOLVABLE" ]; then
      exit 1
    fi
    # Fully-qualified heads/ — a tag with the same name must not win.
    sha=\$(GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git rev-parse "refs/heads/\$ref" 2>/dev/null)
    [ -z "\$sha" ] && exit 1
    echo "\$sha"
    exit 0
    ;;
  *"commits/"*)
    target=\$(printf '%s' "\$args" | sed -E 's#.*commits/([^ ]+).*#\1#')
    if ! GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git cat-file -e "\${target}^{commit}" 2>/dev/null; then
      exit 1
    fi
    parents=\$(GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git show -s --format='%P' "\$target")
    tree=\$(GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git rev-parse "\${target}^{tree}")
    p0=\$(printf '%s' "\$parents" | awk '{print \$1}')
    p1=\$(printf '%s' "\$parents" | awk '{print \$2}')
    p2=\$(printf '%s' "\$parents" | awk '{print \$3}')
    if [ -n "\$p2" ]; then
      pj="[{\"sha\":\"\$p0\"},{\"sha\":\"\$p1\"},{\"sha\":\"\$p2\"}]"
    elif [ -n "\$p1" ]; then
      pj="[{\"sha\":\"\$p0\"},{\"sha\":\"\$p1\"}]"
    elif [ -n "\$p0" ]; then
      pj="[{\"sha\":\"\$p0\"}]"
    else
      pj="[]"
    fi
    printf '{"sha":"%s","parents":%s,"commit":{"tree":{"sha":"%s"}}}\n' "\$target" "\$pj" "\$tree"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
}

if command -v git >/dev/null 2>&1; then

  # -------------------------------------------------------------------------
  # Case 8: clean base merge, forge-verified parent[0]==old_sha AND
  # parent[1] an ancestor of the forge-resolved base tip, merge-tree
  # reproduces the forge-reported tree -> true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  echo more-base > "$repo/base2.txt"; g "$repo" add base2.txt; g "$repo" commit -q -m "base moves on"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff main -m "merge main into pr-branch"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "true" ] && mark_pass "forge-verified clean base merge -> true" \
                       || mark_fail "clean base merge carry-over" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 9: non-merge commit (1 parent, per the forge) -> false, never true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  echo more > "$repo/more.txt"; g "$repo" add more.txt; g "$repo" commit -q -m "ordinary commit"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "non-merge commit (1 parent per forge) -> false" \
                        || mark_fail "non-merge commit" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 10: octopus merge (3 parents, per the forge) -> false, never true
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q -b b1; echo b1 > "$repo/b1.txt"; g "$repo" add b1.txt; g "$repo" commit -q -m b1
  g "$repo" checkout -q main
  g "$repo" checkout -q -b b2; echo b2 > "$repo/b2.txt"; g "$repo" add b2.txt; g "$repo" commit -q -m b2
  g "$repo" checkout -q main
  g "$repo" merge -q --no-ff -m "octopus" b1 b2
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "octopus merge (3 parents per forge) -> false" \
                        || mark_fail "octopus merge" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 11: two-parent merge, but first parent is NOT old_sha -> false
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  UNRELATED_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  g "$repo" checkout -q main
  echo more-base > "$repo/base2.txt"; g "$repo" add base2.txt; g "$repo" commit -q -m "base moves on"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff main -m "merge main into pr-branch"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  # OLD_SHA below is deliberately NOT this merge's first parent.
  got=$(carry_over_in "$repo" "$UNRELATED_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "two-parent merge but parent[0] != old_sha -> false" \
                        || mark_fail "wrong parent[0]" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 12: clean two-parent merge shape, but a hand edit makes the
  # merge-tree comparison disagree with the forge-reported tree -> false
  # (conflict resolution / hand edit — this replaces the round-1
  # remerge-diff-text case with a tree-identity comparison, per Hakim A1)
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/shared.txt"; g "$repo" add shared.txt; g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo "pr change" > "$repo/shared.txt"; g "$repo" add shared.txt; g "$repo" commit -q -m "pr edits shared.txt"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  echo "base change" > "$repo/shared.txt"; g "$repo" add shared.txt; g "$repo" commit -q -m "base also edits shared.txt"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff main -m "merge main into pr-branch" 2>/dev/null || true
  # Resolve the conflict by hand instead of letting git's own recursive
  # merge stand — this is exactly the "hand edit" case the merge-tree
  # comparison exists to catch: the recorded tree will not match what
  # `git merge-tree --write-tree` recomputes from the two parents.
  echo "hand-resolved" > "$repo/shared.txt"
  g "$repo" add shared.txt
  g "$repo" commit -q -m "merge main into pr-branch" 2>/dev/null || g "$repo" -c core.editor=true commit -q --no-edit
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "hand-resolved conflict -> merge-tree mismatch -> false" \
                        || mark_fail "hand-resolved conflict" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 13: new_sha is well-formed (40 hex) but no such object exists ->
  # unknown, never true (the forge commit-lookup call fails)
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "0000000000000000000000000000000000000000" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "unknown" ] && mark_pass "well-formed but nonexistent new_sha -> unknown" \
                          || mark_fail "missing object" "got '$got'"

  # -------------------------------------------------------------------------
  # Case 14a: missing repo arg -> unknown
  # Case 14b: missing base_branch arg -> unknown
  # Case 14c: old_sha not 40 hex -> unknown (rejected before any call)
  # Case 14d: new_sha not 40 hex -> unknown (rejected before any call)
  # -------------------------------------------------------------------------
  VALID40="1234567890123456789012345678901234567890"
  got=$(bash -c ". '$LIB'; rex_approval_carries_over '' $VALID40 $VALID40 main")
  [ "$got" = "unknown" ] && mark_pass "missing repo arg -> unknown" \
                          || mark_fail "missing repo arg" "got '$got'"

  got=$(bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $VALID40 $VALID40 ''")
  [ "$got" = "unknown" ] && mark_pass "missing base_branch arg -> unknown" \
                          || mark_fail "missing base_branch arg" "got '$got'"

  got=$(bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo not-a-sha $VALID40 main")
  [ "$got" = "unknown" ] && mark_pass "old_sha not 40 hex -> unknown, rejected before any call" \
                          || mark_fail "old_sha format" "got '$got'"

  got=$(bash -c ". '$LIB'; rex_approval_carries_over irrelevant/repo $VALID40 short main")
  [ "$got" = "unknown" ] && mark_pass "new_sha not 40 hex -> unknown, rejected before any call" \
                          || mark_fail "new_sha format" "got '$got'"

  # -------------------------------------------------------------------------
  # Case A (round-2 required test): a --no-ff merge whose second parent is
  # on a SIDE branch that was never merged into the base -> false. Rex's
  # ancestor check (parent[1] must be an ancestor of the forge-resolved
  # base tip) is what catches this; a parent[0]-only check would have
  # missed it.
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  g "$repo" checkout -q -b side-branch
  echo side > "$repo/side.txt"; g "$repo" add side.txt; g "$repo" commit -q -m "side branch work, never merged to main"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff side-branch -m "merge side-branch into pr-branch"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "side branch not on base -> false (ancestor check)" \
                        || mark_fail "side branch not on base" "got '$got'"

  # -------------------------------------------------------------------------
  # Case B (round-2 required test, THE BYPASS REGRESSION PIN): a --no-ff
  # merge whose second parent DESCENDS from the approved SHA itself — not
  # from the real base at all — must still be rejected. This is exactly the
  # shape the round-1 version missed: it checked parent[0]==old_sha and
  # stopped there, so ANY second parent passed, including one built to look
  # legitimate by descending from the same commit Rex approved.
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  # A branch built FROM old_sha — a descendant of the approved commit, but
  # not derived from main at all, and main's tip never includes it.
  g "$repo" checkout -q -b descendant-of-approved "$OLD_SHA"
  echo malicious > "$repo/malicious.txt"; g "$repo" add malicious.txt
  g "$repo" commit -q -m "a descendant of the approved commit, not the real base"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff descendant-of-approved -m "merge descendant-of-approved into pr-branch"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "REGRESSION PIN: descendant-of-approved 2nd parent, not the real base -> false" \
                        || mark_fail "REGRESSION: bypass via descendant of approved SHA" "got '$got' (want false — this is the exact bug Rex B1 found)"

  # -------------------------------------------------------------------------
  # Case C (round-2 required test): the base tip cannot be resolved from
  # the forge (name lookup fails) -> unknown, never true.
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  echo more-base > "$repo/base2.txt"; g "$repo" add base2.txt; g "$repo" commit -q -m "base moves on"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff main -m "merge main into pr-branch"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  # "main" is deliberately made unresolvable by the mock, modelling a forge
  # name-lookup failure (renamed/deleted branch, API hiccup, etc.).
  make_rex_carry_gh_mock "$sb" "$repo" "main"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "unknown" ] && mark_pass "unresolvable base tip -> unknown, never true" \
                          || mark_fail "unresolvable tip" "got '$got'"

  # -------------------------------------------------------------------------
  # Case D (#1456): a grafts entry in the real clone invents an ancestor
  # link between parent[1] and the base tip. Pre-#1456 merge-base ran in
  # the real GIT_DIR and would return true; isolated GIT_DIR ignores
  # grafts -> false.
  # Fail-before: on #1443 code this case returns true (grafts trusted).
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  BASE_ROOT=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  echo more-main > "$repo/main2.txt"; g "$repo" add main2.txt; g "$repo" commit -q -m "main moves on"
  MAIN_TIP=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q -b side-branch "$BASE_ROOT"
  echo side > "$repo/side.txt"; g "$repo" add side.txt; g "$repo" commit -q -m "side, never on main"
  SIDE_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff side-branch -m "merge side into pr"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  # Graft: make MAIN_TIP appear to also have SIDE_SHA as a parent so a
  # non-isolated merge-base --is-ancestor SIDE MAIN returns true.
  gd="$repo/gitdir"
  mkdir -p "$gd/info"
  echo "$MAIN_TIP $BASE_ROOT $SIDE_SHA" > "$gd/info/grafts"
  # Confirm grafts WOULD poison a non-isolated merge-base (fail-before pin).
  if g "$repo" merge-base --is-ancestor "$SIDE_SHA" "$MAIN_TIP" 2>/dev/null; then
    sb=$(mktemp -d)
    make_rex_carry_gh_mock "$sb" "$repo"
    got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
    rm -rf "$repo" "$sb"
    [ "$got" = "false" ] && mark_pass "#1456 grafts cannot force carry-over -> false" \
                          || mark_fail "#1456 grafts isolation" "got '$got' (want false — grafts must not invent ancestry)"
  else
    rm -rf "$repo"
    mark_fail "#1456 grafts setup" "grafts did not make side an ancestor of main (test setup broken)"
  fi

  # -------------------------------------------------------------------------
  # Case E (#1456): a local merge driver makes merge-tree reproduce a
  # hand-resolved tree. Pre-#1456 merge-tree ran against the real
  # .git/config and would return true; isolated GIT_DIR has no driver ->
  # false.
  # Fail-before: on #1443 code this case returns true (driver trusted).
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/shared.txt"
  echo "shared.txt merge=poison" > "$repo/.gitattributes"
  g "$repo" add shared.txt .gitattributes
  g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo "pr change" > "$repo/shared.txt"; g "$repo" add shared.txt; g "$repo" commit -q -m "pr edits"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  echo "base change" > "$repo/shared.txt"; g "$repo" add shared.txt; g "$repo" commit -q -m "base edits"
  g "$repo" checkout -q pr-branch
  # merge driver signature: write result to %A ($2).
  mkdir -p "$repo/.git-drivers"
  cat > "$repo/.git-drivers/poison.sh" <<'POISON'
#!/bin/bash
printf 'hand-resolved\n' > "$2"
exit 0
POISON
  chmod +x "$repo/.git-drivers/poison.sh"
  g "$repo" config merge.poison.driver "\"$repo/.git-drivers/poison.sh\" %O %A %B"
  g "$repo" merge -q --no-ff main -m "merge main (driver-assisted)" 2>/dev/null || true
  # If merge did not complete via driver, hand-resolve to the same content.
  if [ -n "$(g "$repo" ls-files -u 2>/dev/null)" ]; then
    echo "hand-resolved" > "$repo/shared.txt"
    g "$repo" add shared.txt
    g "$repo" commit -q -m "merge main (hand-resolved)" 2>/dev/null \
      || g "$repo" -c core.editor=true commit -q --no-edit
  fi
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  # Confirm a NON-isolated merge-tree with the driver would match the
  # recorded tree (fail-before pin for #1443).
  P0=$(g "$repo" rev-parse "${NEW_SHA}^1")
  P1=$(g "$repo" rev-parse "${NEW_SHA}^2")
  FORGE_TREE=$(g "$repo" rev-parse "${NEW_SHA}^{tree}")
  driver_tree=$(g "$repo" -c merge.renormalize=false merge-tree --write-tree "$P0" "$P1" 2>/dev/null | head -1 | tr -d '[:space:]')
  sb=$(mktemp -d)
  make_rex_carry_gh_mock "$sb" "$repo"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  if [ "$driver_tree" = "$FORGE_TREE" ]; then
    [ "$got" = "false" ] && mark_pass "#1456 local merge driver cannot force carry-over -> false" \
                          || mark_fail "#1456 merge-driver isolation" "got '$got' (want false — driver must not fool merge-tree); driver_tree matched forge (fail-before would be true)"
  else
    # Driver did not actually influence merge-tree in this git build —
    # still require false (hand-resolved mismatch), but note the weaker pin.
    [ "$got" = "false" ] && mark_pass "#1456 merge-driver case -> false (driver did not match forge tree; mismatch alone blocks)" \
                          || mark_fail "#1456 merge-driver case" "got '$got'"
  fi

  # -------------------------------------------------------------------------
  # Case F (#1456): a tag named like the base branch must NOT change the
  # resolved tip. Tag points at a commit that HAS the side parent as an
  # ancestor; the real branch tip does not. Branches endpoint +
  # refs/heads/ resolution -> false. Fail-before: commits/{ref} that
  # prefers the tag would return true.
  # -------------------------------------------------------------------------
  repo=$(make_git_repo)
  echo base > "$repo/base.txt"; g "$repo" add base.txt; g "$repo" commit -q -m base
  g "$repo" checkout -q -b pr-branch
  echo pr > "$repo/pr.txt"; g "$repo" add pr.txt; g "$repo" commit -q -m "pr work"
  OLD_SHA=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  g "$repo" checkout -q -b side-branch
  echo side > "$repo/side.txt"; g "$repo" add side.txt; g "$repo" commit -q -m "side"
  g "$repo" checkout -q -b tag-shadow-tip main
  g "$repo" merge -q --no-ff side-branch -m "tag tip includes side"
  TAG_TIP=$(g "$repo" rev-parse HEAD)
  g "$repo" checkout -q main
  # Tag named "main" points at the shadow tip; branch main stays without side.
  g "$repo" tag -f main "$TAG_TIP"
  g "$repo" checkout -q pr-branch
  g "$repo" merge -q --no-ff side-branch -m "merge side into pr"
  NEW_SHA=$(g "$repo" rev-parse HEAD)
  sb=$(mktemp -d)
  # Custom mock: branches/main -> real branch tip; commits/main -> tag tip
  # (models the commits/{ref} shadowing the hardened code must not use).
  mkdir -p "$sb/bin"
  cat > "$sb/bin/gh" <<EOF
#!/bin/bash
REPO_DIR="$repo"
args="\$*"
case "\$args" in
  *"/branches/"*)
    ref=\$(printf '%s' "\$args" | sed -E 's#.*branches/([^ ]+).*#\1#')
    ref=\$(printf '%s' "\$ref" | sed 's/%2[Ff]/\//g')
    sha=\$(GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git rev-parse "refs/heads/\$ref" 2>/dev/null)
    [ -z "\$sha" ] && exit 1
    echo "\$sha"
    exit 0
    ;;
  *"-q .sha"*|*"commits/main"*)
    # Deliberate wrong tip — what commits/{ref} would return if the tag won.
    echo "$TAG_TIP"
    exit 0
    ;;
  *"commits/"*)
    target=\$(printf '%s' "\$args" | sed -E 's#.*commits/([^ ]+).*#\1#')
    if ! GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git cat-file -e "\${target}^{commit}" 2>/dev/null; then
      exit 1
    fi
    parents=\$(GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git show -s --format='%P' "\$target")
    tree=\$(GIT_DIR="\$REPO_DIR/gitdir" GIT_WORK_TREE="\$REPO_DIR" git rev-parse "\${target}^{tree}")
    p0=\$(printf '%s' "\$parents" | awk '{print \$1}')
    p1=\$(printf '%s' "\$parents" | awk '{print \$2}')
    if [ -n "\$p1" ]; then
      pj="[{\"sha\":\"\$p0\"},{\"sha\":\"\$p1\"}]"
    else
      pj="[{\"sha\":\"\$p0\"}]"
    fi
    printf '{"sha":"%s","parents":%s,"commit":{"tree":{"sha":"%s"}}}\n' "\$target" "\$pj" "\$tree"
    exit 0
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$sb/bin/gh"
  got=$(carry_over_in "$repo" "$OLD_SHA" "$NEW_SHA" "main" "$sb/bin")
  rm -rf "$repo" "$sb"
  [ "$got" = "false" ] && mark_pass "#1456 tag cannot shadow base branch tip -> false" \
                        || mark_fail "#1456 tag shadowing" "got '$got' (want false — branches endpoint must win over tag)"

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
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
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
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
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
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
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
  got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
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

# ===========================================================================
# Renames — merge_refresh_required must treat filename AND previous_filename
# as touched, on BOTH the base side and the PR side (me2resh/apexyard#1437
# round-2 review, Rex 3 / Hakim A3). Cases R1, R2, R4.
# ===========================================================================

# Case R1: the base branch RENAMED a file the PR touched under its OLD name.
# The compare entry has filename=new_name, previous_filename=old_name; the
# PR's own file list has only old_name. Must still be required.
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "old_name.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"new_name.txt\",\"previous_filename\":\"old_name.txt\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "R1: base renamed a file under the PR's (old) name -> required" \
                         || mark_fail "R1 base-side rename" "got '$got'"

# Case R2: the PR RENAMED a file the base also touches (under the PR's OLD
# name). The PR's file entry has filename=pr_new_name, previous_filename=
# pr_old_name; the base compare touches pr_old_name as an ordinary (non-
# renamed) file. Must still be required.
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) printf "pr_new_name.txt\npr_old_name.txt\n" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"pr_old_name.txt\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "R2: PR renamed a file the base also touches -> required" \
                         || mark_fail "R2 PR-side rename" "got '$got'"

# Case R4: BOTH sides independently rename the SAME origin file to different
# new names. Neither new name matches, but both previous_filename values do
# (shared_origin.txt). Must still be required.
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) printf "pr_new.txt\nshared_origin.txt\n" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"base_new.txt\",\"previous_filename\":\"shared_origin.txt\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "R4: both sides independently renamed the same origin file -> required" \
                         || mark_fail "R4 both-sides rename" "got '$got'"

# Case R-control: a rename on the base side to a name the PR never touched,
# with no previous_filename overlap either -> skippable (control — proves
# R1/R2/R4 are testing the overlap, not "any rename present at all").
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"docs/renamed-new.md\",\"previous_filename\":\"docs/renamed-old.md\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "skippable" ] && mark_pass "R-control: base rename with no overlap either way -> skippable" \
                          || mark_fail "R-control" "got '$got'"

# ===========================================================================
# "Unknown reads as safe" fail-closed cases (me2resh/apexyard#1437 round-2
# review, Rex 4 / Hakim A4): a null/missing .files, an empty shared-pattern
# list, or an empty PR file list must all return required, never skippable.
# ===========================================================================

# Case U1: .files is explicitly null (not an array) -> required. Before the
# fix, jq's `length` builtin reads `null` as 0, which the old code path
# would have silently misread as "the base touched nothing" -> skippable.
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":null}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "U1: .files is null -> required, not skippable" \
                         || mark_fail "U1 null .files" "got '$got'"

# Case U2: .files is missing entirely from the compare response -> required.
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/base123...main"*) echo "{}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "U2: .files missing from compare response -> required" \
                         || mark_fail "U2 missing .files" "got '$got'"

# Case U3: an empty shared-pattern argument -> required, even with data
# that would otherwise be a clean no-overlap "skippable".
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) echo "src/pr_only.txt" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"docs/unrelated.md\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 ''")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "U3: empty shared-pattern argument -> required" \
                         || mark_fail "U3 empty patterns" "got '$got'"

# Case U4: an empty PR file list (rc=0, but no files at all) -> required —
# every real PR touches at least one file, so this reads as a swallowed API
# problem, not a genuinely fileless PR.
sb=$(make_sandbox_with_gh_script '
case "$*" in
  *"pulls/1/files"*) printf "" ;;
  *"compare/base123...main"*) echo "{\"files\":[{\"filename\":\"docs/unrelated.md\"}]}" ;;
esac
')
got=$(PATH="$sb/bin:$PATH" bash -c ". '$LIB'; merge_refresh_required me2resh/apexyard main 1 base123 '.claude/hooks/_lib-*.sh'")
rm -rf "$sb"
[ "$got" = "required" ] && mark_pass "U4: empty PR file list -> required" \
                         || mark_fail "U4 empty PR files" "got '$got'"

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

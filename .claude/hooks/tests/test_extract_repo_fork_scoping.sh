#!/bin/bash
# test_extract_repo_fork_scoping.sh — regression coverage for the #887
# same-repo-fork-PR class of bug in `extract_repo_from_command`'s gh
# "last resort" fallback (_lib-extract-pr.sh).
#
# #898 already fixed `pr_base_repo` (see test_pr_base_repo.sh) by requiring
# an explicit <repo> arg instead of trusting gh's ambient default. The
# follow-up review on #887 found the SAME unscoped-gh-query pattern still
# alive in extract_repo_from_command's step-3 fallback: when a merge command
# carries neither `--repo`/`-R` nor a parseable API path, the function asks
# gh "which repo does the current branch's PR belong to" via a BARE
# `gh pr view --json headRepository` — no `--repo`. In a fork checkout with
# both `origin` (the fork) and `upstream` (the canonical parent) configured,
# gh's ambient default-repo resolution prefers a remote literally named
# "upstream" over "origin" — so that bare call can succeed with the WRONG
# repo instead of failing, exactly like the original pr_base_repo bug.
#
# The fix: resolve the checkout's OWN repo from its `origin` remote FIRST
# (deterministic, not a guess) and scope the gh query to it; the unscoped
# ambient call is now only a last-last-resort for the rare case where origin
# itself can't be resolved (no git remote at all).
#
# gh is mocked via a file-driven stub (same shape as test_pr_base_repo.sh):
# scoped to the CORRECT (origin) repo → succeeds with the right answer;
# called WITHOUT --repo at all → returns a deliberately WRONG answer, so the
# test fails loudly if the fix ever regresses to the unscoped call.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-extract-pr.sh"
# shellcheck source=/dev/null
. "$LIB"

PASS=0; FAIL=0; FAILED=""
assert_eq() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1));
  else echo "FAIL [$1]: want [$2] got [$3]" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}

MOCKBIN=$(mktemp -d)
cat > "$MOCKBIN/gh" <<'EOF'
#!/bin/bash
# mock gh (--repo-aware, #887-aware):
#   - --repo == ORIGIN_REPO_EXPECT  → success, prints "$CORRECT_REPO".
#   - --repo == anything else       → fails (gh 404).
#   - --repo omitted                → prints "$WRONG_REPO" if set (models
#                                      gh's ambient/parent-preferring default
#                                      resolving successfully to the WRONG
#                                      repo). A fixed implementation must
#                                      never hit this branch when an origin
#                                      remote is configured.
repo=""
scoped=0
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; scoped=1; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$scoped" -eq 0 ]; then
  if [ -n "${WRONG_REPO:-}" ]; then printf '%s' "$WRONG_REPO"; exit 0; fi
  exit 1
fi
if [ "$repo" != "${ORIGIN_REPO_EXPECT:-}" ]; then exit 1; fi
printf '%s' "${CORRECT_REPO:-}"
EOF
chmod +x "$MOCKBIN/gh"
export PATH="$MOCKBIN:$PATH"

# Build a real git repo with BOTH an `origin` (fork) and `upstream` (parent)
# remote — the exact layout that triggers gh's ambient parent-preference.
SBX=$(mktemp -d)
(
  cd "$SBX" || exit 1
  git init -q
  git remote add origin https://github.com/atlas-apex/apexyard.git
  git remote add upstream https://github.com/me2resh/apexyard.git
)

# --- 1. THE #887 REGRESSION GUARD -----------------------------------------
# A merge-ish command with no --repo/-R and no parseable API path forces the
# step-3 "last resort" gh path. Scoped-to-origin succeeds with the CORRECT
# repo; the ambient/unscoped branch (if ever hit) would return WRONG_REPO.
GOT1=$(
  cd "$SBX" || exit 1
  export ORIGIN_REPO_EXPECT="atlas-apex/apexyard"
  export CORRECT_REPO="atlas-apex/apexyard"
  export WRONG_REPO="me2resh/apexyard"
  extract_repo_from_command "gh pr merge --squash"
)
assert_eq "#887 same-repo-fork: origin-scoped call wins over ambient parent-preferring default" \
  "atlas-apex/apexyard" "$GOT1"

# --- 2. No origin remote resolvable → falls through to the unscoped call --
# (the only remaining path that hits gh's ambient default — by design, since
# there is nothing deterministic left to scope to).
SBX_NOREMOTE=$(mktemp -d)
(
  cd "$SBX_NOREMOTE" || exit 1
  git init -q
)
GOT2=$(
  cd "$SBX_NOREMOTE" || exit 1
  export WRONG_REPO="ambient/fallback"
  extract_repo_from_command "gh pr merge --squash"
)
assert_eq "no origin remote → last-last-resort ambient call still fires" \
  "ambient/fallback" "$GOT2"

# --- 3. --repo flag still takes priority over the step-3 fallback entirely,
#        (regression check: the new origin-scoping must not shadow step 2).
GOT3=$(
  cd "$SBX" || exit 1
  unset ORIGIN_REPO_EXPECT CORRECT_REPO WRONG_REPO 2>/dev/null
  extract_repo_from_command "gh pr merge 42 --repo explicit/repo --squash"
)
assert_eq "explicit --repo flag still wins (step 2 unaffected)" "explicit/repo" "$GOT3"

rm -rf "$MOCKBIN" "$SBX" "$SBX_NOREMOTE"
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS  FAIL: 0"; exit 0
else
  echo "PASS: $PASS  FAIL: $FAIL  (failed: $FAILED)"; exit 1
fi

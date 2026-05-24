#!/bin/bash
# Smoke test for the --from-dev hidden flag in /update (#250).
#
# /update is a markdown skill, not a shell script — there's no direct
# binary to invoke. This test pins the bash recipe the skill spec
# documents (flag parse → banner → fetch → preview against the right
# ref → no state mutation under --dry-run) so the recipe stays
# runnable and the spec stays internally consistent.
#
# Cases:
#   1. --from-dev sets UPSTREAM_REF=upstream/dev (not upstream/main)
#   2. --from-dev sets BRANCH_SUFFIX=sync-upstream-dev (not -apexyard)
#   3. Without --from-dev, defaults are upstream/main + sync-upstream-apexyard
#   4. Banner prints when --from-dev is set, BEFORE fetch
#   5. Banner does NOT print without --from-dev
#   6. --from-dev --dry-run on a synthetic fork:
#       - banner appears
#       - preview compares HEAD against upstream/dev
#       - no state change (HEAD unchanged, no new branch, no new commits)
#   7. SKILL.md frontmatter description does NOT mention --from-dev
#   8. SKILL.md ## Usage section DOES mention --from-dev
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL="$SRC_ROOT/.claude/skills/update/SKILL.md"

[ -f "$SKILL" ] || { echo "FAIL: missing $SKILL" >&2; exit 1; }

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

# ---------------------------------------------------------------------
# The flag-parse recipe from the skill, pulled into a function so each
# case can call it with different argv. Keep this in lockstep with the
# pre-step bash block in SKILL.md.
# ---------------------------------------------------------------------
parse_flags() {
  FROM_DEV=0
  DRY_RUN=0
  # REBASE is set but not read in this test — kept in lockstep with the
  # pre-step bash block in SKILL.md (which DOES read it for the merge/rebase
  # branch). Tests assert ref/branch resolution only; the rebase path is
  # exercised by the existing /update tests on the default flow. The
  # `: "${REBASE}"` reference after the case statement keeps shellcheck
  # happy without scope-confusing disable directives on individual branches
  # (which trip SC1124).
  REBASE=0
  for arg in "$@"; do
    case "$arg" in
      --from-dev) FROM_DEV=1 ;;
      --dry-run)  DRY_RUN=1 ;;
      --rebase)   REBASE=1 ;;
    esac
  done
  : "${REBASE}"

  if [ "$FROM_DEV" = "1" ]; then
    UPSTREAM_REF=upstream/dev
    BRANCH_SUFFIX=sync-upstream-dev
  else
    UPSTREAM_REF=upstream/main
    BRANCH_SUFFIX=sync-upstream-apexyard
  fi
}

# Banner contents — matches the skill's pre-step output verbatim.
print_banner_if_dev() {
  if [ "$FROM_DEV" = "1" ]; then
    cat <<'EOB'
⚠ PRE-RELEASE SYNC — pulling from upstream/dev
   This is unreleased work; expect breakage.
   Revert with: git reset --hard origin/main
   For supported updates, use /update (no flag) to pull tagged releases.
EOB
  fi
}

# ---------------------------------------------------------------------
# Case 1 — --from-dev sets UPSTREAM_REF=upstream/dev
# ---------------------------------------------------------------------
echo "Case 1 — --from-dev sets UPSTREAM_REF=upstream/dev"
parse_flags --from-dev
if [ "$UPSTREAM_REF" = "upstream/dev" ]; then
  mark_pass "UPSTREAM_REF=upstream/dev"
else
  mark_fail "UPSTREAM_REF=upstream/dev" "got '$UPSTREAM_REF'"
fi

# ---------------------------------------------------------------------
# Case 2 — --from-dev sets BRANCH_SUFFIX=sync-upstream-dev
# ---------------------------------------------------------------------
echo "Case 2 — --from-dev sets BRANCH_SUFFIX=sync-upstream-dev"
parse_flags --from-dev
if [ "$BRANCH_SUFFIX" = "sync-upstream-dev" ]; then
  mark_pass "BRANCH_SUFFIX=sync-upstream-dev"
else
  mark_fail "BRANCH_SUFFIX=sync-upstream-dev" "got '$BRANCH_SUFFIX'"
fi

# ---------------------------------------------------------------------
# Case 3 — defaults without --from-dev
# ---------------------------------------------------------------------
echo "Case 3 — no --from-dev → defaults"
parse_flags --dry-run
if [ "$UPSTREAM_REF" = "upstream/main" ] && [ "$BRANCH_SUFFIX" = "sync-upstream-apexyard" ]; then
  mark_pass "defaults preserved"
else
  mark_fail "defaults preserved" "got UPSTREAM_REF=$UPSTREAM_REF BRANCH_SUFFIX=$BRANCH_SUFFIX"
fi

# ---------------------------------------------------------------------
# Case 4 — banner prints with --from-dev
# ---------------------------------------------------------------------
echo "Case 4 — --from-dev prints PRE-RELEASE banner"
parse_flags --from-dev
banner_out=$(print_banner_if_dev)
if echo "$banner_out" | grep -q "PRE-RELEASE SYNC"; then
  mark_pass "banner emitted"
else
  mark_fail "banner emitted" "got: $banner_out"
fi
if echo "$banner_out" | grep -q "Revert with: git reset --hard origin/main"; then
  mark_pass "banner has revert hint"
else
  mark_fail "banner has revert hint" "missing revert hint"
fi

# ---------------------------------------------------------------------
# Case 5 — no banner without --from-dev
# ---------------------------------------------------------------------
echo "Case 5 — plain /update prints NO banner"
parse_flags
banner_out=$(print_banner_if_dev)
if [ -z "$banner_out" ]; then
  mark_pass "no banner without --from-dev"
else
  mark_fail "no banner without --from-dev" "got banner: $banner_out"
fi

# ---------------------------------------------------------------------
# Case 6 — --from-dev --dry-run on a synthetic fork: banner + preview
# against upstream/dev + no state change.
# ---------------------------------------------------------------------
echo "Case 6 — --from-dev --dry-run smoke (synthetic fork)"

SBOX=$(mktemp -d)
trap 'rm -rf "$SBOX"' EXIT

# Build an upstream with a main branch and a dev branch with extra commits.
UPSTREAM="$SBOX/upstream"
mkdir -p "$UPSTREAM"
(
  cd "$UPSTREAM" || exit 1
  git init -q -b main
  git config user.email t@t && git config user.name t
  echo "init" > a.txt && git add a.txt && git commit -q -m "init"
  echo "v1" >> a.txt && git commit -q -am "v1.0.0"
  git tag v1.0.0
  git checkout -q -b dev
  echo "dev work 1" >> a.txt && git commit -q -am "feat: dev work 1"
  echo "dev work 2" >> a.txt && git commit -q -am "feat: dev work 2"
  echo "dev work 3" >> a.txt && git commit -q -am "feat: dev work 3"
  git checkout -q main
) || { mark_fail "build upstream" "git init failed"; FAIL=$((FAIL+1)); }

# Clone fork from upstream's main, configure upstream remote.
FORK="$SBOX/fork"
git clone -q "$UPSTREAM" "$FORK" 2>/dev/null
(
  cd "$FORK" || exit 1
  git config user.email f@f && git config user.name f
  git remote rename origin upstream 2>/dev/null
  git remote add origin "$UPSTREAM" 2>/dev/null  # synthetic origin
  git fetch -q upstream
  git fetch -q origin
) || { mark_fail "build fork" "clone failed"; FAIL=$((FAIL+1)); }

# Snapshot HEAD + branches before running the recipe.
HEAD_BEFORE=$(cd "$FORK" && git rev-parse HEAD)
BRANCHES_BEFORE=$(cd "$FORK" && git branch --list | sort)

# Run the recipe inside the fork (banner + preview + dry-run exit).
RUN_OUT=$(
  cd "$FORK" || exit 1
  parse_flags --from-dev --dry-run
  print_banner_if_dev

  # Preview step — count commits between HEAD and the resolved upstream ref.
  AHEAD=$(git rev-list --count "$UPSTREAM_REF"..main 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count main.."$UPSTREAM_REF" 2>/dev/null || echo 0)
  echo "PREVIEW: ref=$UPSTREAM_REF ahead=$AHEAD behind=$BEHIND"

  # Dry-run exits without state mutation. No checkout, no merge.
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN: exiting without state change"
    exit 0
  fi
)

if echo "$RUN_OUT" | grep -q "PRE-RELEASE SYNC"; then
  mark_pass "synthetic run prints banner"
else
  mark_fail "synthetic run prints banner" "got: $RUN_OUT"
fi

if echo "$RUN_OUT" | grep -q "ref=upstream/dev"; then
  mark_pass "preview uses upstream/dev"
else
  mark_fail "preview uses upstream/dev" "got: $RUN_OUT"
fi

# Confirm dev had real new commits to preview (BEHIND>=1 against dev).
if echo "$RUN_OUT" | grep -Eq "behind=[1-9][0-9]*"; then
  mark_pass "preview detects dev commits"
else
  mark_fail "preview detects dev commits" "got: $RUN_OUT"
fi

HEAD_AFTER=$(cd "$FORK" && git rev-parse HEAD)
BRANCHES_AFTER=$(cd "$FORK" && git branch --list | sort)

if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
  mark_pass "no state mutation: HEAD unchanged"
else
  mark_fail "no state mutation: HEAD unchanged" "before=$HEAD_BEFORE after=$HEAD_AFTER"
fi

if [ "$BRANCHES_BEFORE" = "$BRANCHES_AFTER" ]; then
  mark_pass "no state mutation: no new branches"
else
  mark_fail "no state mutation: no new branches" "before=$BRANCHES_BEFORE after=$BRANCHES_AFTER"
fi

# ---------------------------------------------------------------------
# Case 7 — SKILL.md description frontmatter does NOT mention --from-dev
# (hidden semantics, per #250 AC).
# ---------------------------------------------------------------------
echo "Case 7 — --from-dev hidden from description frontmatter"
DESC_LINE=$(awk '/^description:/{print; exit}' "$SKILL")
if echo "$DESC_LINE" | grep -q "from-dev"; then
  mark_fail "hidden from description" "found 'from-dev' in: $DESC_LINE"
else
  mark_pass "hidden from description"
fi

# ---------------------------------------------------------------------
# Case 8 — SKILL.md ## Usage AND ## Options sections DO mention --from-dev
# (operators who read the spec must be able to find it).
# ---------------------------------------------------------------------
echo "Case 8 — --from-dev documented in ## Usage and ## Options"
# Extract the body from the first ## Usage heading to the next blank line
# after the closing fence — coarse but sufficient for a presence check.
USAGE_BLOCK=$(awk '/^## Usage/{flag=1} flag{print} /^## /{ if (NR>1 && !/^## Usage/) {flag=0} }' "$SKILL")
if echo "$USAGE_BLOCK" | grep -q -- "--from-dev"; then
  mark_pass "## Usage mentions --from-dev"
else
  mark_fail "## Usage mentions --from-dev" "not found in Usage block"
fi

OPTIONS_BLOCK=$(awk '/^## Options/{flag=1} flag{print} /^## /{ if (NR>1 && !/^## Options/) {flag=0} }' "$SKILL")
if echo "$OPTIONS_BLOCK" | grep -q -- "--from-dev"; then
  mark_pass "## Options mentions --from-dev"
else
  mark_fail "## Options mentions --from-dev" "not found in Options block"
fi

# ---------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED" >&2
  exit 1
fi
exit 0

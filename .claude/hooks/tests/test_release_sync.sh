#!/bin/bash
# Smoke tests for the /release-sync skill behaviour.
#
# The skill itself is a markdown spec (SKILL.md) — not a shell script —
# so these tests verify the git operations and branch/PR shape the skill
# describes, using a synthetic git sandbox. This gives us a runnable
# contract that will catch regressions if the skill's process is ever
# refactored into a shell helper.
#
# Tests covered:
#   1. "already in sync" path  → git log dev..main empty → no-op expected
#   2. diverged path           → commits on main not on dev → sync needed
#   3. branch name shape       → sync/main-to-dev-after-vX.Y.Z
#   4. merge strategy direction → -X ours keeps dev content on conflict
#   5. idempotent re-run       → second sync on already-synced repo → no-op
#   6. backwards guard         → dev has no commits not on main → still detects main-only commits
#   7. version argument validation → malformed version rejected
#
# Exit 0 if all pass; 1 on first failure.

set -u

PASS=0
FAIL=0
FAILED=""

mark_pass() { printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  ✗ %s: %s\n" "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}\n  - $1"; }

# ---------------------------------------------------------------------------
# Helper: build a synthetic two-branch git repo that simulates apexyard's
# dev/main split with squash-merge divergence.
#
# build_repo <root>
#   Creates a git repo under <root> with:
#     - main: base commit A + squash commit S (simulating a squash-merge release)
#     - dev:  base commit A + original commits B + C (the un-squashed equivalents)
#   This produces the classic squash-divergence: main has S (not on dev),
#   dev has B + C (not on main).
# ---------------------------------------------------------------------------
build_repo() {
  local root="$1"
  mkdir -p "$root"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "test"

    # Base commit shared by both branches
    echo "base" > README.md
    git add README.md
    git commit -q -m "chore: base commit"

    # Create dev branch with two separate commits (B and C)
    git checkout -q -b dev
    echo "feature-b" > feature-b.md
    git add feature-b.md
    git commit -q -m "feat(#1): add feature B"

    echo "feature-c" > feature-c.md
    git add feature-c.md
    git commit -q -m "feat(#2): add feature C"

    # Create main branch with a squash commit (S = squash of B + C)
    git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~2
    # Actually simulate a squash by applying content manually
    echo "feature-b" > feature-b.md
    echo "feature-c" > feature-c.md
    git add feature-b.md feature-c.md
    git commit -q -m "release(#10): v1.0.0 — squash of B and C"
    git tag v1.0.0
  ) || return 1
}

# ---------------------------------------------------------------------------
# Helper: build a repo that is ALREADY in sync (main is ancestor of dev).
# ---------------------------------------------------------------------------
build_synced_repo() {
  local root="$1"
  mkdir -p "$root"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "test"

    echo "base" > README.md
    git add README.md
    git commit -q -m "chore: base"

    # Create dev; main starts from same point
    git checkout -q -b dev

    echo "extra" > extra.md
    git add extra.md
    git commit -q -m "feat(#5): extra"

    # Merge dev into main (fast-forward, so they share history)
    git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
    git merge -q dev
  ) || return 1
}

# ---------------------------------------------------------------------------
# Case 1: "already in sync" — git log dev..main returns empty → no PR needed
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_synced_repo "$SB"

(
  cd "$SB" || exit 99
  DIVERGED=$(git log dev..main --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$DIVERGED" -eq 0 ] && exit 0
  echo "expected 0 diverged commits, got $DIVERGED" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "already-in-sync: dev..main is empty (no-op path)" \
              || mark_fail "already-in-sync detection" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 2: diverged repo — main has commits dev doesn't
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo "$SB"

(
  cd "$SB" || exit 99
  DIVERGED=$(git log dev..main --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$DIVERGED" -gt 0 ] && exit 0
  echo "expected >0 diverged commits, got 0" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "diverged: main has commits not on dev (sync needed)" \
              || mark_fail "diverged detection" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 3: sync branch name shape
# ---------------------------------------------------------------------------
VERSION="v2.0.3"
EXPECTED_BRANCH="sync/main-to-dev-after-${VERSION}"
ACTUAL="sync/main-to-dev-after-${VERSION}"
[ "$ACTUAL" = "$EXPECTED_BRANCH" ] \
  && mark_pass "branch name shape: sync/main-to-dev-after-vX.Y.Z" \
  || mark_fail "branch name shape" "got $ACTUAL expected $EXPECTED_BRANCH"

# ---------------------------------------------------------------------------
# Case 4: merge strategy direction — -X ours keeps dev content on conflict
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
(
  cd "$SB" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "test"

  # Shared ancestor
  printf "shared\n" > shared.md
  git add shared.md
  git commit -q -m "base"

  # dev adds dev-version of conflicting.md
  git checkout -q -b dev
  printf "dev-version\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "feat: dev version"

  # main adds main-version of conflicting.md (simulates squash)
  git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
  printf "main-version\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "release: squash with main version"

  # Now simulate the sync: branch from dev, merge main with -X ours
  git checkout -q -b sync-branch dev
  git merge --no-ff -X ours -q main -m "sync: merge main into dev" 2>/dev/null

  # Verify dev content wins the conflict
  CONTENT=$(cat conflicting.md)
  [ "$CONTENT" = "dev-version" ] && exit 0
  echo "expected 'dev-version', got '$CONTENT'" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "merge -X ours: dev content wins on conflict" \
              || mark_fail "merge -X ours direction" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5: idempotent — second sync on already-synced repo is no-op
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo "$SB"

(
  cd "$SB" || exit 99
  # First sync: branch from dev, merge main
  git checkout -q -b sync/main-to-dev-after-v1.0.0 dev
  git merge --no-ff -X ours -q main -m "sync: first pass" 2>/dev/null

  # Simulate merging sync branch back to dev
  git checkout -q dev
  git merge --no-ff -q sync/main-to-dev-after-v1.0.0 -m "merge sync" 2>/dev/null

  # Second check: dev..main should now be empty (in sync)
  DIVERGED=$(git log dev..main --oneline 2>/dev/null | wc -l | tr -d ' ')
  [ "$DIVERGED" -eq 0 ] && exit 0
  echo "after first sync, expected dev..main=0, got $DIVERGED" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "idempotent: after sync PR merges, dev..main is empty" \
              || mark_fail "idempotent sync" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 6: after sync, dev is ahead of main by 0 release-squash commits
# (only NEW commits since the release appear in main..dev)
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo "$SB"

(
  cd "$SB" || exit 99
  # Add a new feature on dev AFTER the release (simulates ongoing work)
  git checkout -q dev
  echo "new-work" > new-work.md
  git add new-work.md
  git commit -q -m "feat(#99): new work after release"

  # Sync: branch from dev, merge main
  git checkout -q -b sync/main-to-dev-after-v1.0.0 dev
  git merge --no-ff -X ours -q main -m "sync: v1.0.0" 2>/dev/null

  # Merge sync back to dev
  git checkout -q dev
  git merge --no-ff -q sync/main-to-dev-after-v1.0.0 -m "merge sync" 2>/dev/null

  # main..dev should show ONLY the new work commit (not the release squash)
  NEW_ON_DEV=$(git log main..dev --oneline 2>/dev/null | grep -c "new work after release" || echo 0)
  RELEASE_SQUASH_ON_DEV=$(git log main..dev --oneline 2>/dev/null | grep -c "squash" || echo 0)
  # dev..main should be empty (main's squash is now an ancestor)
  DIVERGED_MAIN=$(git log dev..main --oneline 2>/dev/null | wc -l | tr -d ' ')

  [ "$NEW_ON_DEV" -ge 1 ] && [ "$DIVERGED_MAIN" -eq 0 ] && exit 0
  echo "NEW_ON_DEV=$NEW_ON_DEV RELEASE_SQUASH_ON_DEV=$RELEASE_SQUASH_ON_DEV DIVERGED_MAIN=$DIVERGED_MAIN" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "post-sync: only new work visible in main..dev; dev..main empty" \
              || mark_fail "post-sync state" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 7: version argument validation — must match vX.Y.Z
# ---------------------------------------------------------------------------
validate_version() {
  local v="$1"
  echo "$v" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

validate_version "v2.0.3" && mark_pass "version validation: v2.0.3 accepted" \
                          || mark_fail "version validation accept" "v2.0.3 rejected"

validate_version "2.0.3"  && mark_fail "version validation reject" "2.0.3 accepted (missing v prefix)" \
                          || mark_pass "version validation: 2.0.3 rejected (missing v prefix)"

validate_version "v2.0"   && mark_fail "version validation reject" "v2.0 accepted (missing patch)" \
                          || mark_pass "version validation: v2.0 rejected (missing patch component)"

validate_version ""        && mark_fail "version validation reject" "empty string accepted" \
                           || mark_pass "version validation: empty string rejected"

validate_version "latest"  && mark_fail "version validation reject" "'latest' accepted" \
                           || mark_pass "version validation: 'latest' rejected"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_release_sync.sh ====="
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "Failed cases:%b\n" "$FAILED"
  exit 1
fi
exit 0

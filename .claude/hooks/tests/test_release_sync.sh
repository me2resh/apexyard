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
#   1.  "already in sync" path   → git log dev..main empty → no-op expected
#   2.  diverged path            → commits on main not on dev → sync needed
#   3.  branch name shape        → sync/main-to-dev-after-vX.Y.Z
#   4.  squash-duplicate conflict → resolves toward dev (apexyard#1394)
#   4b. main-only-commit conflict → must NOT auto-resolve (apexyard#1394)
#   5.  idempotent re-run        → second sync on already-synced repo → no-op
#   6.  backwards guard          → dev has no commits not on main → still detects main-only commits
#   7.  version argument validation → malformed version rejected
#   8-10. CHANGELOG carry-forward (apexyard#448) — unaffected by the merge
#         strategy change, kept as regression coverage
#   11. general main-only-commit shape → blind `-X ours` drops the row;
#       commit-attributed resolution keeps it (apexyard#1394). NOT the real
#       apexyard#1348 shape — see case 13.
#   12. post-merge content check (step 5c) → flags the case-11 loss, passes
#       clean on the correctly-resolved merge (apexyard#1394)
#   B2. annotated-tag peeling → bare rev-parse is the tag object,
#       `^{commit}` is the commit (me2resh/apexyard#1406 Rex finding B2)
#   13. the REAL apexyard#1348 shape → the release squash commit is the
#       SOLE touching commit AND carries a release-branch-only edit; the
#       Released-From confirmation must call it unsafe (#1406 Rex finding B3)
#   14. B3 control → a genuine squash-duplicate (no release-branch edit)
#       still classifies safe, so the common case stays unattended
#
# Exit 0 if all pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SKILL_MD="$SRC_ROOT/.claude/skills/release-sync/SKILL.md"

PASS=0
FAIL=0
FAILED=""

mark_pass() { printf "  ✓ %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  ✗ %s: %s\n" "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}\n  - $1"; }

# ---------------------------------------------------------------------------
# B4 (me2resh/apexyard#1406 Rex finding): static assertions on SKILL.md
# itself, not on a copy of its logic. The earlier version of this file
# reached 17/17 pass against the pre-fix SKILL.md, which still said
# `-X ours` — because every other case here exercises a re-implementation
# of the skill's git operations, never the skill's own text. Each assertion
# below is written so it fails on the pre-fix file:
#   - the step 5 merge command still says -X ours
#   - the tag resolution does not peel to the commit
#   - step 5c (the post-merge content check) is absent
#   - the Released-From confirmation (B3's fix) is absent
# ---------------------------------------------------------------------------
if [ ! -f "$SKILL_MD" ]; then
  mark_fail "B4: SKILL.md exists" "not found at $SKILL_MD"
else
  # Match an actual invocation (`git merge ... -X ours`), not the prose
  # that explains why the skill no longer uses it — that prose legitimately
  # says the phrase "-X ours" several times.
  if grep -qE 'git merge[^`]*-X ours' "$SKILL_MD"; then
    mark_fail "B4: step 5 merge has no -X ours" "found a 'git merge ... -X ours' invocation in $SKILL_MD"
  else
    mark_pass "B4: step 5 merge has no -X ours"
  fi

  if grep -q '\^{commit}' "$SKILL_MD"; then
    mark_pass "B4: tag resolution peels to the commit (^{commit})"
  else
    mark_fail "B4: tag resolution peels to the commit (^{commit})" "no '^{commit}' found in $SKILL_MD"
  fi

  if grep -q '^### 5c\.' "$SKILL_MD"; then
    mark_pass "B4: step 5c (post-merge content check) is present"
  else
    mark_fail "B4: step 5c (post-merge content check) is present" "no '### 5c.' heading found in $SKILL_MD"
  fi

  if grep -q 'Released-From' "$SKILL_MD"; then
    mark_pass "B4/B3: the Released-From confirmation is present"
  else
    mark_fail "B4/B3: the Released-From confirmation is present" "no 'Released-From' reference found in $SKILL_MD"
  fi
fi

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
    git tag -a v1.0.0 -m "v1.0.0"  # annotated (B2): matches auto-tag-on-release-pr-merge.yml
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
# Helper: classify_conflict_file <dev_ref> <main_ref> <release_sha> <file>
# Mirrors SKILL.md step 5a exactly: list the commits on main-not-on-dev that
# touched <file>; if the ONLY one is <release_sha>, the conflict is a
# squash-duplicate (safe to resolve toward dev); any other commit in that
# list makes it a main-only-commit conflict (must stop and ask).
# ---------------------------------------------------------------------------
classify_conflict_file() {
  local dev_ref="$1" main_ref="$2" release_sha="$3" file="$4"
  local touching
  touching=$(git log "${dev_ref}..${main_ref}" --format=%H -- "$file" 2>/dev/null)
  if [ -z "$touching" ]; then
    echo "no-conflict"
  elif [ "$touching" = "$release_sha" ]; then
    echo "squash-duplicate"
  else
    echo "main-only-commit"
  fi
}

# ---------------------------------------------------------------------------
# Case 4: squash-duplicate conflict resolves toward dev (apexyard#1394)
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

  # main adds main-version of conflicting.md via the ONLY release squash
  # commit on main — the classic squash-duplicate shape.
  git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
  printf "main-version\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "release(#10): squash with main version"
  git tag -a v9.9.9 -m "v9.9.9"  # annotated (B2): matches auto-tag-on-release-pr-merge.yml
  RELEASE_SHA=$(git rev-parse "v9.9.9^{commit}")

  # Plain merge (NOT -X ours) — conflicts, since both sides touched the file.
  git checkout -q -b sync-branch dev
  git merge --no-ff -q main -m "sync: merge main into dev" 2>/dev/null

  CLASS=$(classify_conflict_file dev main "$RELEASE_SHA" conflicting.md)
  if [ "$CLASS" != "squash-duplicate" ]; then
    echo "expected classification 'squash-duplicate', got '$CLASS'" >&2
    exit 1
  fi

  # Resolve toward dev, per the classification, and finish the merge.
  git checkout --ours -- conflicting.md
  git add conflicting.md
  git commit --no-edit -q

  CONTENT=$(cat conflicting.md)
  [ "$CONTENT" = "dev-version" ] && exit 0
  echo "expected 'dev-version' after squash-duplicate resolution, got '$CONTENT'" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "squash-duplicate conflict: classified correctly, resolves toward dev" \
              || mark_fail "squash-duplicate resolution" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 4b: main-only-commit conflict must NOT auto-resolve (apexyard#1394)
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
(
  cd "$SB" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "test"

  printf "shared\n" > shared.md
  git add shared.md
  git commit -q -m "base"

  git checkout -q -b dev
  printf "dev-version\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "feat: dev version"

  git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
  # The release squash commit does NOT touch conflicting.md this time —
  # only a SEPARATE, main-only hotfix commit does.
  echo "unrelated" > unrelated.md
  git add unrelated.md
  git commit -q -m "release(#10): squash, unrelated file only"
  git tag -a v9.9.8 -m "v9.9.8"  # annotated (B2): matches auto-tag-on-release-pr-merge.yml
  RELEASE_SHA=$(git rev-parse "v9.9.8^{commit}")

  printf "main-only-hotfix\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "fix: hotfix landed straight on main, never on dev"

  git checkout -q -b sync-branch dev
  git merge --no-ff -q main -m "sync: merge main into dev" 2>/dev/null

  CLASS=$(classify_conflict_file dev main "$RELEASE_SHA" conflicting.md)
  [ "$CLASS" = "main-only-commit" ] && exit 0
  echo "expected classification 'main-only-commit', got '$CLASS'" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "main-only-commit conflict: classified correctly, must stop and ask" \
              || mark_fail "main-only-commit classification" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 5: idempotent — second sync on already-synced repo is no-op
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo "$SB"

(
  cd "$SB" || exit 99
  # First sync: branch from dev, merge main (plain merge — build_repo's
  # feature-b.md/feature-c.md are identical add-add on both sides, so this
  # does not conflict and needs no attribution step).
  git checkout -q -b sync/main-to-dev-after-v1.0.0 dev
  git merge --no-ff -q main -m "sync: first pass" 2>/dev/null

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

  # Sync: branch from dev, merge main (plain merge — no conflict here either)
  git checkout -q -b sync/main-to-dev-after-v1.0.0 dev
  git merge --no-ff -q main -m "sync: v1.0.0" 2>/dev/null

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
# Helper: build a sync branch already in the post-state we want to test
# step 5b against. The contract of step 5b is:
#
#   "If CHANGELOG.md on the sync branch differs from main's CHANGELOG.md,
#    replace it with main's and commit as a separate atomic commit."
#
# How that drift came about isn't part of the contract — multiple mechanics
# can produce it (a prior `/release-sync` run that didn't carry forward,
# a manual main edit between releases, divergence from a hand-written
# CHANGELOG bump on dev that doesn't match main, etc). The test sets up
# the drift state directly so the carry-forward step is exercised against
# the condition it's documented to handle, not against one specific path
# that led there. See apexyard#448 for the design notes.
#
# build_sync_branch_with_changelog_drift <root>
#   Creates a repo with:
#     - main: CHANGELOG with v2.1.0 + v2.0.0 + v1.0.0 entries
#     - sync branch: CHANGELOG stuck at v1.0.0 (the drift), plus an
#       unrelated code commit on top (so step 5b's commit lands above it
#       and we can assert "only CHANGELOG.md touched in step 5b's commit").
# ---------------------------------------------------------------------------
build_sync_branch_with_changelog_drift() {
  local root="$1"
  mkdir -p "$root"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "test"

    # Base commit: shared CHANGELOG with only v1.0.0.
    printf '%s\n' "# Changelog" "" "## [1.0.0] — 2026-01-01" "" "- initial release" > CHANGELOG.md
    echo "base" > README.md
    git add CHANGELOG.md README.md
    git commit -q -m "chore: base commit"

    # main branch: advance CHANGELOG with v2.0.0 then v2.1.0 entries.
    git checkout -q -b main
    printf '%s\n' "# Changelog" "" \
      "## [2.1.0] — 2026-05-24" "" "- latest release" "" \
      "## [2.0.0] — 2026-05-24" "" "- previous release" "" \
      "## [1.0.0] — 2026-01-01" "" "- initial release" > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: advance CHANGELOG to v2.1.0"
    git tag -a v2.1.0 -m "v2.1.0"  # annotated (B2): matches auto-tag-on-release-pr-merge.yml

    # Sync branch: simulate the post-step-5 state where the sync branch's
    # CHANGELOG drifted from main's. We branch from base (so CHANGELOG is
    # still at v1.0.0), then add an unrelated code commit on top so step
    # 5b's commit lands above it.
    git checkout -q -b "sync/main-to-dev-after-v2.1.0" main~1
    echo "feature-b" > feature-b.md
    git add feature-b.md
    git commit -q -m "feat(#1): add feature B"
  ) || return 1
}

# Run step 5b's carry-forward logic against the current working tree. The
# function returns 0 if a carry-forward commit was created, 1 if no commit
# was needed (idempotent path). Echoes the new commit SHA on stdout when
# a commit is created. Mirrors the SKILL.md bash exactly so the test is
# verifying the prescribed contract, not a re-implementation.
run_carry_forward() {
  if ! git diff --quiet main -- CHANGELOG.md; then
    git checkout main -- CHANGELOG.md
    if ! git diff --quiet --cached -- CHANGELOG.md \
        || ! git diff --quiet -- CHANGELOG.md; then
      git add CHANGELOG.md
      git commit -q -m "sync: carry forward CHANGELOG.md from main after vX.Y.Z release

Refs #448"
      git rev-parse HEAD
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Case 8 (apexyard#448): CHANGELOG drift → carry-forward creates a commit
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_sync_branch_with_changelog_drift "$SB"
(
  cd "$SB" || exit 99
  # Pre-condition: sync branch's CHANGELOG drifts from main's.
  if git diff --quiet main -- CHANGELOG.md; then
    echo "pre-condition failed: sync branch CHANGELOG already matches main" >&2
    exit 1
  fi
  # Run the carry-forward (step 5b).
  CF_SHA=$(run_carry_forward) || { echo "carry-forward returned no-op when drift existed" >&2; exit 1; }
  # Post-condition: CHANGELOG now matches main exactly.
  if ! git diff --quiet main -- CHANGELOG.md; then
    echo "post-condition failed: CHANGELOG still drifts from main after carry-forward" >&2
    exit 1
  fi
  # Post-condition: the carry-forward commit IS the most-recent commit that touched CHANGELOG.
  if [ "$(git log -1 --format=%H -- CHANGELOG.md)" != "$CF_SHA" ]; then
    echo "post-condition failed: carry-forward SHA is not the last CHANGELOG-touching commit" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "carry-forward (apexyard#448): creates a commit when CHANGELOG drifted from main" \
              || mark_fail "carry-forward drift case" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 9 (apexyard#448): idempotent — no commit when CHANGELOG already matches
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_sync_branch_with_changelog_drift "$SB"
(
  cd "$SB" || exit 99
  # First run: should create a commit (drift exists).
  run_carry_forward > /dev/null || { echo "first run unexpectedly no-op" >&2; exit 1; }
  COMMITS_AFTER_FIRST=$(git rev-list HEAD | wc -l | tr -d ' ')
  # Second run: should be a no-op (CHANGELOG now matches main).
  if run_carry_forward > /dev/null; then
    echo "second run unexpectedly created a commit (idempotency broken)" >&2
    exit 1
  fi
  COMMITS_AFTER_SECOND=$(git rev-list HEAD | wc -l | tr -d ' ')
  if [ "$COMMITS_AFTER_FIRST" != "$COMMITS_AFTER_SECOND" ]; then
    echo "commit count changed on idempotent re-run: $COMMITS_AFTER_FIRST → $COMMITS_AFTER_SECOND" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "carry-forward (apexyard#448): idempotent — second run is no-op" \
              || mark_fail "carry-forward idempotency" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 10 (apexyard#448): carry-forward only touches CHANGELOG.md
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_sync_branch_with_changelog_drift "$SB"
(
  cd "$SB" || exit 99
  CF_SHA=$(run_carry_forward) || { echo "carry-forward unexpectedly no-op" >&2; exit 1; }
  # The commit's name-only diff must be CHANGELOG.md and nothing else.
  TOUCHED=$(git show --name-only --format="" "$CF_SHA" | grep -v '^$')
  if [ "$TOUCHED" != "CHANGELOG.md" ]; then
    echo "carry-forward touched files other than CHANGELOG.md: '$TOUCHED'" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "carry-forward (apexyard#448): touches only CHANGELOG.md" \
              || mark_fail "carry-forward scope" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Helper: build a general main-only-commit shape — main has the release
# squash PLUS a SEPARATE main-only commit (the contributor row) touching the
# SAME file the squash also touches. This is the shape a blind `-X ours`
# cannot get right: the squash commit's presence in the conflict-causing
# list does not mean it is the ONLY commit that matters.
#
# This is NOT the real apexyard#1348 shape — #1348's contributor rows were
# added directly on the release branch, inside the squash commit, with no
# separate later commit. See build_repo_with_release_branch_edit below for
# that shape (Rex's B3 finding on #1406).
#
# build_repo_with_main_only_hotfix <root>
#   - main:   base -> release squash (touches README.md) -> hotfix commit
#             (also touches README.md, adds a contributor row main-only)
#   - dev:    base -> feature commit (touches README.md differently)
# ---------------------------------------------------------------------------
build_repo_with_main_only_hotfix() {
  local root="$1"
  mkdir -p "$root"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "test"

    printf '%s\n' "# README" "" "- core-maintainer" > README.md
    git add README.md
    git commit -q -m "chore: base commit"

    git checkout -q -b dev
    printf '%s\n' "# README" "" "- core-maintainer" "- new-dev-feature" > README.md
    git add README.md
    git commit -q -m "feat(#1): document new-dev-feature"

    git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
    printf '%s\n' "# README" "" "- core-maintainer" "- squash-of-dev-content" > README.md
    git add README.md
    git commit -q -m "release(#10): v1.0.0 squash"
    git tag -a v1.0.0 -m "v1.0.0"  # annotated (B2): matches auto-tag-on-release-pr-merge.yml

    # A commit that landed straight on main, never on dev, via a SEPARATE
    # hotfix commit — a general main-only-commit shape. This is NOT the real
    # apexyard#1348 shape (see build_repo_with_release_branch_edit below and
    # Rex's B3 finding on #1406): #1348's contributor rows were added
    # directly on the release branch, inside the squash commit itself, not
    # by a later separate commit. Kept as its own general-case coverage.
    printf '%s\n' "# README" "" "- core-maintainer" "- squash-of-dev-content" "- new-contributor-row" > README.md
    git add README.md
    git commit -q -m "docs: add new-contributor-row (main-only, never on dev)"
  ) || return 1
}

# ---------------------------------------------------------------------------
# Case 11 (general main-only-commit shape, apexyard#1394): blind `-X ours`
# drops a main-only row added by a SEPARATE hotfix commit; commit-attributed
# resolution keeps it. This models a main-only commit in general — NOT the
# real apexyard#1348 shape. See case 13 below for that.
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo_with_main_only_hotfix "$SB"
(
  cd "$SB" || exit 99
  RELEASE_SHA=$(git rev-parse "v1.0.0^{commit}")

  # --- OLD behaviour: blind -X ours ---
  git checkout -q -b sync-old dev
  git merge --no-ff -X ours -q main -m "sync: old blind strategy" 2>/dev/null
  if grep -q "new-contributor-row" README.md; then
    echo "pre-condition broken: -X ours did not reproduce the drop" >&2
    exit 1
  fi

  # --- NEW behaviour: plain merge, classify, stop on main-only-commit ---
  git checkout -q dev
  git checkout -q -b sync-new dev
  git merge --no-ff -q main -m "sync: new attributed strategy" 2>/dev/null
  CLASS=$(classify_conflict_file dev main "$RELEASE_SHA" README.md)
  if [ "$CLASS" != "main-only-commit" ]; then
    echo "expected README.md to classify as main-only-commit, got '$CLASS'" >&2
    exit 1
  fi
  # Per the skill: a main-only-commit conflict is resolved by hand, not
  # blindly. Simulate the user's resolution keeping BOTH sides' content.
  printf '%s\n' "# README" "- new-dev-feature" "" "- core-maintainer" "- squash-of-dev-content" "- new-contributor-row" > README.md
  git add README.md
  git commit --no-edit -q

  if ! grep -q "new-contributor-row" README.md; then
    echo "new strategy still lost the main-only row" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "main-only commit (separate hotfix): -X ours drops the row; attributed resolution keeps it" \
              || mark_fail "main-only-commit repro" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Helper: main_only_commit_applies <commit>
# Mirrors SKILL.md step 5c: a commit's patch reverse-applying cleanly means
# its content is present, unchanged, in the current working tree.
# ---------------------------------------------------------------------------
main_only_commit_applies() {
  local commit="$1"
  git apply --check --reverse <(git show --binary "$commit") >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Case 12 (general main-only-commit shape, apexyard#1394): post-merge
# content check (step 5c) — flags the loss under the old strategy, passes
# clean under the new one. Same caveat as case 11: models a main-only
# commit in general, not the real apexyard#1348 shape (see case 13).
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo_with_main_only_hotfix "$SB"
(
  cd "$SB" || exit 99
  # Resolve the hotfix commit by its message, not by position — avoids any
  # assumption about commit ordering on main.
  HOTFIX_SHA=$(git log -1 --format=%H --grep="new-contributor-row" main)

  # --- Old strategy: check fails (content lost) ---
  git checkout -q -b sync-old-check dev
  git merge --no-ff -X ours -q main -m "sync: old" 2>/dev/null
  if main_only_commit_applies "$HOTFIX_SHA"; then
    echo "pre-condition broken: old strategy's tree still passes the check" >&2
    exit 1
  fi

  # --- New strategy: resolve by hand (keep both sides), check passes ---
  git checkout -q dev
  git checkout -q -b sync-new-check dev
  git merge --no-ff -q main -m "sync: new" 2>/dev/null
  printf '%s\n' "# README" "- new-dev-feature" "" "- core-maintainer" "- squash-of-dev-content" "- new-contributor-row" > README.md
  git add README.md
  git commit --no-edit -q

  if ! main_only_commit_applies "$HOTFIX_SHA"; then
    echo "post-merge check still fails after attributed resolution" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "post-merge check (step 5c): flags a main-only-commit loss, clean after attributed resolution" \
              || mark_fail "post-merge content check" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case (B2): an annotated tag's bare rev-parse names the tag OBJECT, not
# the commit it points at. The `^{commit}` suffix peels it to the commit,
# regardless of tag type. This is what auto-tag-on-release-pr-merge.yml
# actually creates (`git tag -a`) — a lightweight tag would not show this
# split, which is why the pre-fix skill's own tests (using lightweight
# tags) never caught B2.
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
(
  cd "$SB" || exit 99
  git init -q
  git config user.email "test@test.com"
  git config user.name "test"
  echo "base" > f.md
  git add f.md
  git commit -q -m "chore: base"
  COMMIT_SHA=$(git rev-parse HEAD)
  git tag -a v3.0.0 -m "v3.0.0"

  BARE=$(git rev-parse v3.0.0)
  PEELED=$(git rev-parse "v3.0.0^{commit}")

  if [ "$BARE" = "$COMMIT_SHA" ]; then
    echo "expected the bare tag rev-parse to differ from the commit on an annotated tag, got the same value" >&2
    exit 1
  fi
  if [ "$PEELED" != "$COMMIT_SHA" ]; then
    echo "expected the peeled tag rev-parse to equal the commit SHA, got '$PEELED' vs '$COMMIT_SHA'" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "B2: annotated tag — bare rev-parse is the tag object, ^{commit} is the commit" \
              || mark_fail "B2 tag peeling" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Helper: classify_squash_duplicate_safe <release_sha> <file>
# Mirrors SKILL.md step 5a's Released-From confirmation exactly. Given a
# file already classified "squash-duplicate" by classify_conflict_file
# (release_sha is the ONLY main-not-on-dev commit that touched it), decide
# whether it is actually safe to resolve toward dev:
#   - "safe"   the release commit's Released-From trailer names a dev
#              commit, and the file is unchanged between that commit and
#              the release commit — confirmed equivalent to dev.
#   - "unsafe" the trailer is missing, or the file differs — route to the
#              same stop-and-ask path as a main-only-commit conflict.
# ---------------------------------------------------------------------------
classify_squash_duplicate_safe() {
  local release_sha="$1" file="$2"
  local released_from
  released_from=$(git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly)' "$release_sha" 2>/dev/null)
  if [ -z "$released_from" ]; then
    echo "unsafe"
    return
  fi
  if git diff --quiet "$released_from" "$release_sha" -- "$file" 2>/dev/null; then
    echo "safe"
  else
    echo "unsafe"
  fi
}

# ---------------------------------------------------------------------------
# Helper: build the REAL apexyard#1348 shape (Rex's B3 finding on #1406).
# The release squash commit is the ONLY commit main has that dev does not —
# so classify_conflict_file alone reports "squash-duplicate" — but its
# content for the conflicting file does NOT match the dev commit named in
# its own Released-From trailer. The contributor row was written directly
# on the release branch, before the squash, and never merged to dev first.
# This is what #1348 case 11 above does NOT model: there, the lost row came
# from a SEPARATE later commit; here, the release squash commit itself
# carries content dev never had, while still being the sole touching commit.
#
# build_repo_with_release_branch_edit <root>
#   - dev:  base -> feature commit (adds "new-dev-feature" to README.md)
#   - main: base -> release squash, Released-From: <dev tip>, README.md =
#           dev's content PLUS a row added directly on the release branch
# ---------------------------------------------------------------------------
build_repo_with_release_branch_edit() {
  local root="$1"
  mkdir -p "$root"
  (
    cd "$root" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "test"

    printf '%s\n' "# README" "" "- core-maintainer" > README.md
    git add README.md
    git commit -q -m "chore: base commit"

    git checkout -q -b dev
    printf '%s\n' "# README" "" "- core-maintainer" "- new-dev-feature" > README.md
    git add README.md
    git commit -q -m "feat(#1): document new-dev-feature"
    DEV_TIP=$(git rev-parse dev)

    git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
    printf '%s\n' "# README" "" "- core-maintainer" "- new-dev-feature" "- new-contributor-row" > README.md
    git add README.md
    git commit -q -m "release(#10): v1.0.0 squash

Adds a contributor row written directly on the release branch, before
the squash, never merged to dev first.

Released-From: $DEV_TIP"
    git tag -a v1.0.0-real1348 -m "v1.0.0-real1348"
  ) || return 1
}

# ---------------------------------------------------------------------------
# Case 13 (B3, the REAL apexyard#1348 shape): a squash-duplicate candidate
# whose release-branch edit the naive classification alone would miss.
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
build_repo_with_release_branch_edit "$SB"
(
  cd "$SB" || exit 99
  RELEASE_SHA=$(git rev-parse "v1.0.0-real1348^{commit}")

  git checkout -q -b sync-branch dev
  git merge --no-ff -q main -m "sync: attributed strategy" 2>/dev/null

  CLASS=$(classify_conflict_file dev main "$RELEASE_SHA" README.md)
  if [ "$CLASS" != "squash-duplicate" ]; then
    echo "expected README.md to classify as squash-duplicate (release_sha is the sole touching commit), got '$CLASS'" >&2
    exit 1
  fi

  # --- Pre-fix behaviour: classification alone says "safe", checkout
  # --ours drops the release-branch row. This is the #1348 loss reproduced.
  git checkout -q --ours -- README.md
  if grep -q "new-contributor-row" README.md; then
    echo "pre-condition broken: naive squash-duplicate resolution did not reproduce the #1348 drop" >&2
    exit 1
  fi

  # --- B3 fix: the Released-From confirmation must say "unsafe" for this
  # file, routing it to stop-and-ask instead of a blind checkout --ours.
  SAFE=$(classify_squash_duplicate_safe "$RELEASE_SHA" README.md)
  if [ "$SAFE" != "unsafe" ]; then
    echo "expected classify_squash_duplicate_safe to say 'unsafe' (release branch edited this file), got '$SAFE'" >&2
    exit 1
  fi
  exit 0
)
[ "$?" -eq 0 ] && mark_pass "B3: real #1348 shape — squash-duplicate confirmation catches the release-branch edit" \
              || mark_fail "B3 real #1348 shape" "see output above"
rm -rf "$SB"

# ---------------------------------------------------------------------------
# Case 14 (B3 control): a genuine squash-duplicate — the release commit
# changed nothing relative to its Released-From dev commit — must still be
# classified "safe", so the common case keeps resolving toward dev
# unattended and does not regress into asking on every sync.
# ---------------------------------------------------------------------------
SB=$(mktemp -d) && SB=$(cd "$SB" && pwd -P)
(
  cd "$SB" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "test"

  printf "shared\n" > shared.md
  git add shared.md
  git commit -q -m "base"

  git checkout -q -b dev
  printf "dev-version\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "feat: dev version"
  DEV_TIP=$(git rev-parse dev)

  # A genuine squash-duplicate: the release commit's content for this file
  # is IDENTICAL to dev's tip content (the release branch added nothing new
  # here) — the case the fix must still resolve toward dev unattended.
  git checkout -q main 2>/dev/null || git checkout -q -b main HEAD~1
  printf "dev-version\n" > conflicting.md
  git add conflicting.md
  git commit -q -m "release(#10): squash, no release-branch edit to this file

Released-From: $DEV_TIP"
  git tag -a v9.9.7 -m "v9.9.7"
  RELEASE_SHA=$(git rev-parse "v9.9.7^{commit}")

  SAFE=$(classify_squash_duplicate_safe "$RELEASE_SHA" conflicting.md)
  [ "$SAFE" = "safe" ] && exit 0
  echo "expected a genuine squash-duplicate to classify 'safe', got '$SAFE'" >&2
  exit 1
)
[ "$?" -eq 0 ] && mark_pass "B3 control: genuine squash-duplicate (no release-branch edit) stays safe" \
              || mark_fail "B3 control: genuine squash-duplicate stays safe" "see output above"
rm -rf "$SB"

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

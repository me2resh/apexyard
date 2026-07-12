#!/usr/bin/env bash
# Tests for bin/release-changelog.sh (AgDR-0076).
#
# Strategy: create a temporary git repo with fake commits, then call the
# script against that repo and assert on the stdout output. No network
# calls; no reliance on the main repo's actual history.
#
# Each test function runs its git commands via a subshell that cd's into
# a fresh tmpdir, so tests never bleed into one another or into the main
# repo's history.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/../../../bin" && pwd)"
CHANGELOG_SCRIPT="$BIN_DIR/release-changelog.sh"

pass=0; fail=0

# ── Assertion helpers ────────────────────────────────────────────────────────

eq() {  # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1"
    echo "       expected: [$2]"
    echo "       got:      [$3]"
    fail=$((fail + 1))
  fi
}

contains() {  # contains <label> <needle> <haystack>
  if echo "$3" | grep -qF "$2"; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 — expected to find [$2] in output"
    echo "  Output was:"
    echo "$3" | head -20 | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

not_contains() {  # not_contains <label> <needle> <haystack>
  if ! echo "$3" | grep -qF "$2"; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 — expected NOT to find [$2] in output"
    echo "  Offending line:"
    echo "$3" | grep -F "$2" | head -3 | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

# ── Per-test repo runner ─────────────────────────────────────────────────────
# run_in_repo <shell-function-body>
# Creates a tmpdir, sources a mini-function that can call git, then cleans up.
# Returns the captured output + exit code from the inner body.

run_test() {
  # $@ is a list of git commands + the final assertion call
  local tmpdir
  tmpdir=$(mktemp -d)
  (
    cd "$tmpdir" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    git config init.defaultBranch main 2>/dev/null || true

    mc() {  # make_commit <msg>
      local f="f$RANDOM.txt"
      echo "$RANDOM" > "$f"
      git add "$f"
      git commit -q -m "$1"
    }

    # Run the caller-supplied body
    eval "$1"
  )
  local rc=$?
  rm -rf "$tmpdir"
  return $rc
}

# ── Test: missing required env var fails with exit 1 ────────────────────────

echo "--- missing env var ---"
out=$(PREV_TAG="" HEAD_REF="HEAD" VERSION="v1.0.0" DATE="2026-01-01" \
  bash "$CHANGELOG_SCRIPT" 2>&1 || true)
contains "missing PREV_TAG prints error" "PREV_TAG is required" "$out"

# ── Test: empty commit range (patch with 0 commits) ─────────────────────────

echo "--- empty commit range ---"
out=$(run_test '
  mc "chore: initial setup"
  git tag v0.0.1
  PREV_TAG="v0.0.1" HEAD_REF="HEAD" VERSION="v0.0.2" DATE="2026-01-01" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "header line present" "## [v0.0.2] — 2026-01-01" "$out"
contains "patch release description" "Patch release" "$out"
not_contains "no Added section" "### Added" "$out"
not_contains "no Fixed section" "### Fixed" "$out"

# ── Test: feat commits → Added section, minor bump description ──────────────

echo "--- feat commits ---"
out=$(run_test '
  mc "chore: initial"
  git tag v1.0.0
  mc "feat(#101): add auto-tag workflow"
  mc "feat(#102): add dry-run mode to release skill"
  PREV_TAG="v1.0.0" HEAD_REF="HEAD" VERSION="v1.1.0" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "header line" "## [v1.1.0] — 2026-06-21" "$out"
contains "minor bump" "Minor release" "$out"
contains "Added section" "### Added (feat)" "$out"
contains "first feat subject" "add auto-tag workflow" "$out"
contains "second feat subject" "add dry-run mode" "$out"
contains "PR ref 101" "(#101)" "$out"
contains "PR ref 102" "(#102)" "$out"
contains "Closes section" "### Closes" "$out"
contains "closes 101 in closes" "#101" "$out"

# ── Test: fix commits → Fixed section, patch bump description ───────────────

echo "--- fix commits ---"
out=$(run_test '
  mc "chore: initial"
  git tag v2.0.0
  mc "fix(#200): correct tag placement after squash merge"
  PREV_TAG="v2.0.0" HEAD_REF="HEAD" VERSION="v2.0.1" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "patch bump" "Patch release" "$out"
contains "Fixed section" "### Fixed (fix)" "$out"
contains "fix subject" "correct tag placement" "$out"
not_contains "no Added section" "### Added" "$out"

# ── Test: breaking commit → Breaking section, major bump description ─────────

echo "--- breaking commit ---"
out=$(run_test '
  mc "chore: initial"
  git tag v1.2.3
  mc "feat(#300)!: remove deprecated v1 skill API"
  PREV_TAG="v1.2.3" HEAD_REF="HEAD" VERSION="v2.0.0" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "major bump" "Major release" "$out"
contains "Breaking section" "### Breaking" "$out"
contains "breaking subject" "remove deprecated v1 skill API" "$out"

# ── Test: mixed commit types → multiple sections ─────────────────────────────

echo "--- mixed commit types ---"
out=$(run_test '
  mc "chore: initial"
  git tag v3.0.0
  mc "feat(#401): new skill /foo"
  mc "fix(#402): fix bar edge case"
  mc "chore(#403): update dependencies"
  mc "docs(#404): improve getting-started guide"
  PREV_TAG="v3.0.0" HEAD_REF="HEAD" VERSION="v3.1.0" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "Added section" "### Added (feat)" "$out"
contains "Fixed section" "### Fixed (fix)" "$out"
contains "Changed section" "### Changed (refactor / chore / docs)" "$out"
contains "feat subject" "new skill /foo" "$out"
contains "fix subject" "fix bar edge case" "$out"
contains "chore subject" "update dependencies" "$out"
contains "docs subject" "improve getting-started guide" "$out"

# ── Test: commits without PR numbers still appear (no (#N) required) ─────────

echo "--- commits without PR numbers ---"
out=$(run_test '
  mc "chore: initial"
  git tag v4.0.0
  mc "fix: correct shell quoting in release script"
  PREV_TAG="v4.0.0" HEAD_REF="HEAD" VERSION="v4.0.1" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "fix without PR num appears" "correct shell quoting" "$out"
not_contains "no spurious closes section" "### Closes" "$out"

# ── Test: NONE as PREV_TAG includes all commits ──────────────────────────────

echo "--- NONE prev tag ---"
out=$(run_test '
  mc "feat(#500): initial feature"
  PREV_TAG="NONE" HEAD_REF="HEAD" VERSION="v1.0.0" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "feat from beginning" "initial feature" "$out"

# ── Test: sync and release commits are excluded ──────────────────────────────

echo "--- excluded commit types ---"
# Ordering mirrors the real release-cut workflow (#737): the sync marker lands
# FIRST (reconciling the prior release), THEN the new feat for this release, then
# the release commit. The post-sync-boundary range therefore includes the feat
# (unreleased) and excludes the sync (it's the boundary) and the release commit.
out=$(run_test '
  mc "chore: initial"
  git tag v5.0.0
  mc "sync: merge main into dev after v5.0.0 release"
  mc "feat(#600): real feature"
  mc "release(#601): v5.1.0"
  PREV_TAG="v5.0.0" HEAD_REF="HEAD" VERSION="v5.1.0" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "real feat included" "real feature" "$out"
not_contains "sync commit excluded" "merge main into dev" "$out"
not_contains "release commit excluded" "release(#601)" "$out"

# ── Test: Merge branch commits excluded, Merge pull request kept ──────────────

echo "--- merge commit filtering ---"
out=$(run_test '
  mc "chore: initial"
  git tag v6.0.0
  mc "feat(#700): add something"
  mc "Merge branch main into dev"
  PREV_TAG="v6.0.0" HEAD_REF="HEAD" VERSION="v6.1.0" DATE="2026-06-21" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "feat included" "add something" "$out"
not_contains "branch merge excluded" "Merge branch main" "$out"

# ── Test: #737 post-sync boundary — released commits after the tag excluded ──
# Squash-model simulation: the tag sits early; "released" commits follow it on
# dev (they were squashed into the tag on main, so a tag-range over-counts them);
# a `/release-sync` marker commit lands; then the true unreleased delta. The fix
# must anchor on the sync marker, NOT the tag — so only the post-sync feat shows.
echo "--- #737 post-sync boundary ---"
out=$(run_test '
  mc "chore: initial"
  git tag v7.0.0
  mc "feat(#710): already-released work one"
  mc "feat(#711): already-released work two"
  mc "sync: merge main into dev after v7.0.0 release"
  mc "feat(#712): the real unreleased delta"
  PREV_TAG="v7.0.0" HEAD_REF="HEAD" VERSION="v7.1.0" DATE="2026-06-28" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains   "post-sync delta included"       "the real unreleased delta" "$out"
not_contains "pre-sync released work excluded (1)" "already-released work one" "$out"
not_contains "pre-sync released work excluded (2)" "already-released work two" "$out"

# ── Test: #737 fallback — no sync marker → merge-base/tag range still works ───
echo "--- #737 fallback (no sync marker) ---"
out=$(run_test '
  mc "chore: initial"
  git tag v8.0.0
  mc "feat(#810): first feature since tag"
  PREV_TAG="v8.0.0" HEAD_REF="HEAD" VERSION="v8.1.0" DATE="2026-06-28" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "fallback still lists the delta" "first feature since tag" "$out"

# ── Test: #737 grep is version-anchored — a prose mention can't hijack the boundary ──
# A commit AFTER the real sync whose subject merely mentions the convention must
# NOT be treated as the boundary. With an unanchored grep it would win
# --max-count=1, set LOG_RANGE=<that>..HEAD, and drop the unreleased delta.
echo "--- #737 version-anchored grep (no prose false-positive) ---"
out=$(run_test '
  mc "chore: initial"
  git tag v9.0.0
  mc "sync: merge main into dev after v9.0.0 release"
  mc "feat(#900): document the sync/main-to-dev-after convention"
  PREV_TAG="v9.0.0" HEAD_REF="HEAD" VERSION="v9.1.0" DATE="2026-06-28" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "feat mentioning the unversioned string still included" "document the sync/main-to-dev-after convention" "$out"

# ── Test: AgDR-0094 (#872) — Released-From trailer wins over the sync heuristic ──
# The v5.0.0 regression case: the prior release-sync PR merged LATE, landing near
# HEAD after real unreleased work. With no trailer, the #737 heuristic anchors on
# that late sync marker and silently drops everything before it. With the trailer
# present on PREV_TAG's own commit, the range anchors on the RECORDED cut sha
# instead — deterministic, and immune to where the sync marker happens to land.
echo "--- AgDR-0094 trailer wins over late sync (v5.0.0 regression) ---"
out=$(run_test '
  mc "chore: initial"
  CUT=$(git rev-parse HEAD)
  git commit -q --allow-empty -m "chore: release v10.0.0" -m "Released-From: $CUT"
  git tag v10.0.0
  mc "feat(#1001): pre-sync unreleased feature one"
  mc "feat(#1002): pre-sync unreleased feature two"
  mc "sync: merge main into dev after v10.0.0 release"
  mc "feat(#1003): post-sync unreleased feature"
  PREV_TAG="v10.0.0" HEAD_REF="HEAD" VERSION="v10.1.0" DATE="2026-07-10" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "pre-sync feature one included (the under-count fix)" "pre-sync unreleased feature one" "$out"
contains "pre-sync feature two included (the under-count fix)" "pre-sync unreleased feature two" "$out"
contains "post-sync feature still included" "post-sync unreleased feature" "$out"
not_contains "release commit itself excluded" "chore: release v10.0.0" "$out"
not_contains "sync commit itself excluded" "merge main into dev after v10.0.0" "$out"

# ── Test: AgDR-0094 — trailer-absent releases keep the old #737 fallback ────────
# PREV_TAG carries no trailer (a pre-AgDR-0094 release, or any plain tag) — the
# range must fall back to the existing sync-boundary heuristic unchanged. This
# is the explicit trailer-absent counterpart to the trailer-present test above;
# every pre-existing #737 case elsewhere in this file is a trailer-absent case
# too, so this one exists mainly to name the fallback path directly.
echo "--- AgDR-0094 trailer-absent falls back to #737 heuristic ---"
out=$(run_test '
  mc "chore: initial"
  git tag v11.0.0
  mc "feat(#1101): already-released work"
  mc "sync: merge main into dev after v11.0.0 release"
  mc "feat(#1102): the real unreleased delta"
  PREV_TAG="v11.0.0" HEAD_REF="HEAD" VERSION="v11.1.0" DATE="2026-07-10" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "post-sync delta included (unchanged #737 behaviour)" "the real unreleased delta" "$out"
not_contains "pre-sync work still excluded (unchanged #737 behaviour)" "already-released work" "$out"

# ── Test: AgDR-0094 — a bogus/unknown trailer sha falls back safely, never errors ──
# A mangled or stale Released-From trailer (sha doesn't resolve to a commit in
# this repo) must not crash the script — it should fall back to the #737
# heuristic exactly as if no trailer existed, and exit 0.
echo "--- AgDR-0094 bogus trailer sha falls back safely ---"
out=$(run_test '
  mc "chore: initial"
  git commit -q --allow-empty -m "chore: release v12.0.0" -m "Released-From: not-a-real-sha"
  git tag v12.0.0
  mc "feat(#1201): unreleased work before late sync"
  mc "sync: merge main into dev after v12.0.0 release"
  mc "feat(#1202): unreleased work after late sync"
  PREV_TAG="v12.0.0" HEAD_REF="HEAD" VERSION="v12.1.0" DATE="2026-07-10" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
  echo "EXIT_CODE=$?"
')
contains "script exits cleanly despite the bogus sha" "EXIT_CODE=0" "$out"
contains "falls back to sync heuristic (post-sync work included)" "unreleased work after late sync" "$out"
not_contains "falls back to sync heuristic (pre-sync work excluded, same as #737 fallback)" "unreleased work before late sync" "$out"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All $pass test(s) passed."
  exit 0
else
  echo "$fail test(s) FAILED (${pass} passed)."
  exit 1
fi

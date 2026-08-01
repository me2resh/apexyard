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
  # "--" stops grep from treating a needle starting with "-" (e.g. "--repo
  # foo") as an option instead of a literal pattern.
  if echo "$3" | grep -qF -- "$2"; then
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
  if ! echo "$3" | grep -qF -- "$2"; then
    echo "  ok: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 — expected NOT to find [$2] in output"
    echo "  Offending line:"
    echo "$3" | grep -F -- "$2" | head -3 | sed 's/^/    /'
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

# ── Test: #1002 — release_desc join has a space after every comma ───────────
# Regression test for the v5.2.0 cut's "2 features,13 fixes,14 improvements."
# (no space after the commas) — `${arr[*]}` with IFS=', ' only joins on the
# first IFS char, silently dropping the space.
echo "--- #1002 release_desc comma spacing ---"
out=$(run_test '
  mc "chore: initial"
  git tag v13.0.0
  mc "feat(#1301): first feature"
  mc "feat(#1302): second feature"
  mc "fix(#1303): first fix"
  mc "chore(#1304): first chore"
  PREV_TAG="v13.0.0" HEAD_REF="HEAD" VERSION="v13.1.0" DATE="2026-07-24" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "space after first comma" "2 features, 1 fix" "$out"
contains "space after second comma" "1 fix, 1 improvement" "$out"
not_contains "no unspaced comma before 'fix'" "features,1" "$out"
not_contains "no unspaced comma before 'improvement'" "fix,1" "$out"

# ── Test: #1002 — RELEASE_CHANGELOG_RANGE is printed to stderr, not stdout ──
# The /release skill's count-mismatch guard needs the exact range the script
# resolved (trailer-anchored or #737-fallback) to compare against, instead of
# the structurally-wrong `main..dev` (#1002). Verify it is emitted on stderr
# (so it never pollutes the changelog markdown on stdout) and matches the
# trailer-anchored range when a trailer is present.
echo "--- #1002 RELEASE_CHANGELOG_RANGE on stderr ---"
stderr_capture=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  CUT=$(git rev-parse HEAD)
  git commit -q --allow-empty -m "chore: release v14.0.0" -m "Released-From: $CUT"
  git tag v14.0.0
  mc "feat(#1401): unreleased feature"
  stdout_out=$(PREV_TAG="v14.0.0" HEAD_REF="HEAD" VERSION="v14.1.0" DATE="2026-07-24" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>"'"$stderr_capture"'")
  echo "STDOUT_HAS_RANGE_LINE=$(echo "$stdout_out" | grep -c "RELEASE_CHANGELOG_RANGE=" || true)"
  echo "EXPECT_SHA=$CUT"
')
stderr_out=$(cat "$stderr_capture")
rm -f "$stderr_capture"
contains "range line NOT on stdout" "STDOUT_HAS_RANGE_LINE=0" "$out"
contains "range line present on stderr" "RELEASE_CHANGELOG_RANGE=" "$stderr_out"
# Cross-check the printed range is anchored on the trailer sha, not main..dev.
expect_sha=$(echo "$out" | grep -oE 'EXPECT_SHA=.*' | cut -d= -f2)
contains "stderr range is anchored on the trailer sha" "RELEASE_CHANGELOG_RANGE=${expect_sha}..HEAD" "$stderr_out"

# ── #1056 helper — a stub `gh` binary for ref-resolution tests ──────────────
# Writes a fake `gh` to <dir>/gh, controlled by env vars the caller sets
# before invoking the changelog script:
#   STUB_GH_BODY     — the PR body text `gh pr view --json body -q .body`
#                       should "return"
#   STUB_GH_EXIT      — non-zero to simulate a `gh` failure — auth, rate
#                       limit, or an unreachable forge, the exact failure
#                       mode hit live during the v5.3.0 cut
#   STUB_GH_SLEEP     — seconds to sleep before responding, to simulate a
#                       hung/unresponsive forge
#   STUB_GH_CALL_LOG  — a file path; every invocation appends its full
#                       argument list here, so tests can assert on exactly
#                       what the script queried (or, since #1076, that it
#                       never queried at all — the log staying EMPTY is now
#                       the expected outcome for every unscoped/cross-repo
#                       commit, not the presence of a particular --repo)
# Every `$` in the heredoc body is backslash-escaped so it survives heredoc
# creation literally and only expands when the stub itself runs later,
# inside the test's own subshell.
make_stub_gh() {  # make_stub_gh <dir>
  mkdir -p "$1"
  cat > "$1/gh" <<STUBEOF
#!/usr/bin/env bash
if [ -n "\${STUB_GH_CALL_LOG:-}" ]; then
  echo "GH_CALLED_WITH: \$*" >> "\$STUB_GH_CALL_LOG"
fi
if [ -n "\${STUB_GH_SLEEP:-}" ]; then
  sleep "\${STUB_GH_SLEEP}"
fi
if [ "\${STUB_GH_EXIT:-0}" != "0" ]; then
  exit "\${STUB_GH_EXIT}"
fi
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
  printf "%s" "\${STUB_GH_BODY:-}"
  exit 0
fi
exit 1
STUBEOF
  chmod +x "$1/gh"
}

# ── Test: #1056 defect 1 — Closes repeats the keyword per reference ─────────
# A comma-joined "Closes #A, #B, #C" line only auto-closes #A — GitHub only
# honours the reference immediately following the closing keyword. Every
# reference must get its own "- Closes #N" bullet so all of them fire.
echo "--- #1056 Closes repeats keyword per reference (>=3 refs) ---"
out=$(run_test '
  mc "chore: initial"
  git tag v15.0.0
  mc "feat(#1501): first unreleased feature"
  mc "fix(#1502): second unreleased fix"
  mc "chore(#1503): third unreleased chore"
  PREV_TAG="v15.0.0" HEAD_REF="HEAD" VERSION="v15.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains   "Closes #1501 own bullet" "Closes #1501" "$out"
contains   "Closes #1502 own bullet" "Closes #1502" "$out"
contains   "Closes #1503 own bullet" "Closes #1503" "$out"
not_contains "no comma-joined Closes line (#1501, #1502 inert-past-first bug)" "Closes #1501, #1502" "$out"
not_contains "no comma-joined Closes line (any pairing)" "#1502, #1503" "$out"

# ── Test: #1056 defect 2 — scoped subject is unaffected (no PR lookup) ──────
# `fix(#1042): ...` — the scope IS the issue number by convention. This must
# resolve straight from the subject with no `gh` call at all (no stub `gh` is
# put on PATH for this test — if the script tried to shell out, it would hit
# whatever real `gh` is on the runner's PATH and could flake or hang).
echo "--- #1056 scoped subject resolves directly, no PR lookup ---"
out=$(run_test '
  mc "chore: initial"
  git tag v16.0.0
  mc "fix(#1600): put the human gate on approval flow (#1601)"
  PREV_TAG="v16.0.0" HEAD_REF="HEAD" VERSION="v16.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains     "closes the ISSUE number from the scope" "Closes #1600" "$out"
not_contains "does not close the trailing PR number instead" "Closes #1601" "$out"

# ── Test: #1076 — unscoped subject never gets a Closes, even when a PR-body
#    lookup WOULD resolve one. `docs: ... (#2001)` has no `type(#N):` scope —
#    the only "(#N)" present is the trailing squash-merge PR number, not an
#    issue. Before #1076 this was resolved via a best-effort `gh pr view`
#    lookup of PR #2001's own body; that mechanism is gone entirely — the
#    governing rule is "prefer a MISSING close over a WRONG close", and an
#    unscoped ref is never confidently an issue number. `gh` is stubbed to
#    RESOLVE SUCCESSFULLY (a legitimate "Refs #2000" in the body) to prove
#    the generator doesn't even attempt the lookup anymore, not merely that
#    it degrades gracefully when the lookup would fail.
echo "--- #1076 unscoped subject: no Closes, no gh call, even when the body would resolve ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v17.0.0
  mc "docs: rework the onboarding flow copy (#2001)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="See also. Refs #2000" STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v17.0.0" HEAD_REF="HEAD" VERSION="v17.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
not_contains "does not close the resolvable issue (no lookup attempted)" "Closes #2000" "$out"
not_contains "does not close the PR number either" "Closes #2001" "$out"
not_contains "no Closes section at all" "### Closes" "$out"
contains     "display line still shows the PR number" "(#2001)" "$out"
eq           "gh is never invoked for an unscoped commit" "" "$call_log_contents"

# ── Test: #1076 — a broken/unreachable `gh` never aborts the release either
#    (moot mechanically, since gh is never called for an unscoped commit —
#    this asserts the "never called" property holds even under the exact
#    failure mode that motivated #1056's original fail-soft handling: a `gh`
#    that errors out, as if from a DNS blip on api.github.com).
echo "--- #1076 unscoped subject: broken gh is still never invoked, script still exits 0 ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v19.0.0
  mc "docs: update the contributing guide (#2201)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_EXIT=1 STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v19.0.0" HEAD_REF="HEAD" VERSION="v19.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
  echo "EXIT_CODE=$?"
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
not_contains "no Closes for the unscoped commit" "Closes #2201" "$out"
contains     "script still exits cleanly" "EXIT_CODE=0" "$out"
eq           "gh is never invoked (nothing to degrade from)" "" "$call_log_contents"

# ── Test: #1076 — a hung `gh` is likewise never invoked; the script never
#    waits on it at all (previously bounded by PR_LOOKUP_TIMEOUT — now there
#    is nothing to bound, because the call never happens).
echo "--- #1076 unscoped subject: hung gh is never invoked, script returns immediately ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v22.0.0
  mc "docs: yet another unscoped change (#2501)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  START=$(date +%s)
  PATH="$fakebin:$PATH" STUB_GH_SLEEP=30 STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v22.0.0" HEAD_REF="HEAD" VERSION="v22.1.0" DATE="2026-07-30" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
  EXIT_CODE=$?
  END=$(date +%s)
  echo "EXIT_CODE=$EXIT_CODE"
  echo "ELAPSED=$((END - START))"
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
not_contains "no Closes for the unscoped commit" "Closes #2501" "$out"
contains     "script still exits cleanly" "EXIT_CODE=0" "$out"
eq           "gh is never invoked (the 30s stub sleep never runs)" "" "$call_log_contents"
elapsed=$(echo "$out" | grep -oE 'ELAPSED=[0-9]+' | cut -d= -f2)
if [ -n "$elapsed" ] && [ "$elapsed" -lt 5 ]; then
  echo "  ok: returns near-instantly, no gh call to wait on (elapsed=${elapsed}s)"
  pass=$((pass + 1))
else
  echo "  FAIL: expected a near-instant return with no gh call - elapsed=${elapsed}s (expected < 5s)"
  fail=$((fail + 1))
fi

# ── #1076 — the five WRONG-close shapes from the issue's own table ─────────
# Each of these produced a live wrong close before #1076. All five must now
# emit NO Closes line (missing is safe; wrong is not).

# Shape 1: a design-doc commit that only DISCUSSES several issues in prose,
# with the real (unscoped) squash PR number trailing at the very end. The old
# "first #N anywhere in the subject" extraction picked up the FIRST discussed
# issue (#347) instead of the actual PR (#352) - and then treated #347 as a
# closeable ref. Unscoped, so no Closes at all now; the display line still
# anchors on the real trailing PR number.
echo "--- #1076 shape 1: design-doc prose mentions are never picked up as Closes ---"
out=$(run_test '
  mc "chore: initial"
  git tag v24.0.0
  mc "docs: write the design for the export epic (design for #347 + #348 + #351) (#352)"
  PREV_TAG="v24.0.0" HEAD_REF="HEAD" VERSION="v24.1.0" DATE="2026-08-01" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
not_contains "does not close the first prose-mentioned issue" "Closes #347" "$out"
not_contains "does not close the other prose-mentioned issues either" "Closes #348" "$out"
not_contains "no Closes section at all (unscoped commit)" "### Closes" "$out"
contains     "display line anchors on the real trailing PR number" "(#352)" "$out"

# Shape 2: an unscoped commit whose prose mentions a FOREIGN repo's issue
# number ("other-repo#12") ahead of its own trailing squash PR ref. The old
# unanchored extraction grabbed "#12" as if it were local - the #207 lesson,
# reintroduced. Unscoped, so no Closes either way now.
echo "--- #1076 shape 2: a foreign-repo mention in prose is never picked up as a local Closes ---"
out=$(run_test '
  mc "chore: initial"
  git tag v25.0.0
  mc "fix: mirror other-repo#12 behaviour (#1046)"
  PREV_TAG="v25.0.0" HEAD_REF="HEAD" VERSION="v25.0.1" DATE="2026-08-01" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
not_contains "does not close the foreign-repo issue number as if local" "Closes #12" "$out"
not_contains "no Closes section at all (unscoped commit)" "### Closes" "$out"

# Shape 3: a revert of a scoped commit must not re-close the issue the
# reverted commit closed.
echo "--- #1076 shape 3: Revert commits never emit a Closes ---"
out=$(run_test '
  mc "chore: initial"
  git tag v26.0.0
  mc "Revert \"fix(#1042): apply the bad migration\""
  PREV_TAG="v26.0.0" HEAD_REF="HEAD" VERSION="v26.0.1" DATE="2026-08-01" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
not_contains "does not re-close what the revert undid" "Closes #1042" "$out"
not_contains "no Closes section at all (revert)" "### Closes" "$out"

# Shape 4: a CROSS-REPO scope. `docs(me2resh/apexyard#148): ...` names an
# issue in a DIFFERENT repo - a bare "Closes #148" would auto-close THIS
# repo's own #148 if it has one, which is the #207 lesson reintroduced. No
# `gh` call should happen either (the old code accidentally reached `gh pr
# view 148`, which only "worked" because 148 happened to be an issue, not a
# PR, and the failure fell back to the same number by coincidence).
echo "--- #1076 shape 4: a cross-repo scope never emits a bare local Closes, and never calls gh ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v27.0.0
  mc "docs(me2resh/apexyard#148): document the cross-repo scope shape (#149)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v27.0.0" HEAD_REF="HEAD" VERSION="v27.0.1" DATE="2026-08-01" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
not_contains "does not emit a bare local Closes for the cross-repo scope" "Closes #148" "$out"
not_contains "no Closes section at all (cross-repo scope)" "### Closes" "$out"
eq          "gh is never invoked for a cross-repo scope" "" "$call_log_contents"

# Shape 5: an unscoped commit whose PR body merely DISCUSSES a closing
# keyword in prose (not an actual resolution) - the old resolve-via-gh-body
# mechanism would have matched it. Since the lookup is gone entirely, gh is
# never even asked, so the prose can never be mistaken for a real reference.
echo "--- #1076 shape 5: prose in a PR body can never be mistaken for a Closes (lookup removed) ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v28.0.0
  mc "docs: mention the old bug in passing (#2701)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="We used to say this Fixes #999, but it does not." STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v28.0.0" HEAD_REF="HEAD" VERSION="v28.0.1" DATE="2026-08-01" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
not_contains "never picks up the prose-mentioned issue" "Closes #999" "$out"
not_contains "no Closes section at all (unscoped commit)" "### Closes" "$out"
eq          "gh is never invoked for an unscoped commit" "" "$call_log_contents"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All $pass test(s) passed."
  exit 0
else
  echo "$fail test(s) FAILED (${pass} passed)."
  exit 1
fi

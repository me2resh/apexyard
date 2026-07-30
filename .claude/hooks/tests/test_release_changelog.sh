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
#   STUB_GH_SLEEP     — (#1078) seconds to sleep before responding, to
#                       simulate a hung/unresponsive forge — the exact
#                       failure mode verified live: no error, no output,
#                       just silence until an external `timeout` killed it
#   STUB_GH_CALL_LOG  — (#1077) a file path; every invocation appends its
#                       full argument list here, so tests can assert on
#                       exactly which --repo the script queried (or that it
#                       never queried at all)
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

# ── Test: #1056 defect 2 — unscoped subject resolves via the PR's own body ──
# `docs: ... (#2001)` has no `type(#N):` scope — the only "(#N)" present is
# the trailing squash-merge PR number, not an issue. The generator must look
# up PR #2001's body, find its "Refs #2000", and close #2000 — not #2001.
echo "--- #1056 unscoped subject resolves issue from PR body (Refs #N) ---"
out=$(run_test '
  mc "chore: initial"
  git tag v17.0.0
  mc "docs: rework the onboarding flow copy (#2001)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="See also. Refs #2000" \
    PREV_TAG="v17.0.0" HEAD_REF="HEAD" VERSION="v17.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains     "resolves to the referenced issue" "Closes #2000" "$out"
not_contains "does not close the PR number itself" "Closes #2001" "$out"
contains     "display line still shows the PR number" "(#2001)" "$out"

# ── Test: #1056 defect 2 — unscoped subject whose PR resolves to nothing ────
# The PR body carries no Closes/Fixes/Resolves/Refs reference at all — the
# generator must degrade to the PR number (today'"'"'s behaviour), not drop the
# entry or crash.
echo "--- #1056 unscoped subject, PR body has no closing reference (falls back to PR number) ---"
out=$(run_test '
  mc "chore: initial"
  git tag v18.0.0
  mc "docs: fix a typo in the README (#2101)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="Just a typo fix, no issue linked." \
    PREV_TAG="v18.0.0" HEAD_REF="HEAD" VERSION="v18.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
contains "falls back to the PR number when nothing resolves" "Closes #2101" "$out"

# ── Test: #1056 fail-soft — an unreachable forge never aborts the release ───
# Simulates the exact failure hit live during the v5.3.0 cut: `gh` errors out
# (DNS blip on api.github.com). The generator must degrade to the PR number
# and exit 0 — a release cut must never abort because the forge was down.
echo "--- #1056 fail-soft: gh failure degrades to PR number, script still exits 0 ---"
out=$(run_test '
  mc "chore: initial"
  git tag v19.0.0
  mc "docs: update the contributing guide (#2201)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_EXIT=1 \
    PREV_TAG="v19.0.0" HEAD_REF="HEAD" VERSION="v19.1.0" DATE="2026-07-29" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
  echo "EXIT_CODE=$?"
')
contains "degrades to the PR number when gh is unreachable" "Closes #2201" "$out"
contains "script still exits cleanly (no abort on forge failure)" "EXIT_CODE=0" "$out"

# ── Test: #1077 — repo is derived from the ACTUAL remote, not hardcoded ─────
# An adopter fork cutting its OWN release must resolve its own PR numbers
# against its OWN repo. REPO_REMOTE="origin" (an adopter fork's own remote,
# not "upstream") points at a repo that is NOT me2resh/apexyard — assert the
# stub actually received --repo testadopter/theirfork, proving derivation
# reads the configured remote instead of a hardcoded default.
echo "--- #1077 repo derived from the actual (non-upstream) remote ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v20.0.0
  mc "docs: rework the release notes template (#2301)"
  git remote add origin https://github.com/testadopter/theirfork.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="Refs #2300" STUB_GH_CALL_LOG="'"$call_log"'" \
    REPO_REMOTE="origin" \
    PREV_TAG="v20.0.0" HEAD_REF="HEAD" VERSION="v20.1.0" DATE="2026-07-30" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
contains     "resolves via the derived (fork) repo" "Closes #2300" "$out"
contains     "gh was actually invoked" "GH_CALLED_WITH:" "$call_log_contents"
contains     "queried the fork's own repo (from origin), not upstream" "--repo testadopter/theirfork" "$call_log_contents"
not_contains "never queried the hardcoded upstream default" "--repo me2resh/apexyard" "$call_log_contents"

# ── Test: #1077 — the DEFAULT-CONFIG adopter fork case, zero REPO_REMOTE ────
# The exact topology the ticket was filed against, with NO explicit
# REPO_REMOTE override at all: an adopter fork that followed apexyard's own
# docs and ran `git remote add upstream ...` (for /update) ALSO has "origin"
# pointing at their own fork, and cuts their OWN release with HEAD_REF
# pointing at their OWN dev branch ("origin/dev") rather than "upstream/dev".
# `refs/remotes/origin/dev` is created directly via update-ref (no real
# network fetch needed) so HEAD_REF resolves to a real ref, exactly mirroring
# a fetched remote-tracking branch.
#
# Before the HEAD_REF-derived REPO_REMOTE fix, REPO_REMOTE defaulted to
# "upstream" unconditionally — which resolves to me2resh/apexyard in this
# topology regardless of which branch is actually being released, byte-
# identical to the hardcode #1077 was filed to remove. This is the case
# that must be fixed with ZERO configuration, not by telling every adopter
# to discover and set REPO_REMOTE=origin by hand.
echo "--- #1077 default-config adopter fork: zero-config derivation via HEAD_REF ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v23.0.0
  mc "docs: rework the release checklist (#2601)"
  git remote add upstream https://github.com/me2resh/apexyard.git
  git remote add origin https://github.com/testadopter2/theirfork.git
  git update-ref refs/remotes/origin/dev HEAD
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="Refs #2600" STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v23.0.0" HEAD_REF="origin/dev" VERSION="v23.1.0" DATE="2026-07-30" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
contains     "resolves via the fork's own repo, derived from HEAD_REF alone (no REPO_REMOTE set)" "Closes #2600" "$out"
contains     "queried origin's own repo (HEAD_REF's remote prefix)" "--repo testadopter2/theirfork" "$call_log_contents"
not_contains "never queried upstream despite it being configured too (the #1077 regression case)" "--repo me2resh/apexyard" "$call_log_contents"

# ── Test: #1077 — underivable remote emits no gh call and no wrong close ────
# No remote at all is configured (no "upstream", no "origin") and REPO_REMOTE
# is left at its default. The repo cannot be derived confidently — per the
# "missing over wrong" principle, the script must NOT fall back to a
# hardcoded repo guess. It should never even invoke `gh`, and the emitted
# Closes bullet is only the PR's own number (a same-repo no-op), never a
# cross-repo guess.
echo "--- #1077 underivable remote: no gh call, no wrong-repo guess ---"
call_log=$(mktemp)
out=$(run_test '
  mc "chore: initial"
  git tag v21.0.0
  mc "docs: another unscoped change (#2401)"
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  PATH="$fakebin:$PATH" STUB_GH_BODY="Refs #9999" STUB_GH_CALL_LOG="'"$call_log"'" \
    PREV_TAG="v21.0.0" HEAD_REF="HEAD" VERSION="v21.1.0" DATE="2026-07-30" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
  echo "EXIT_CODE=$?"
')
call_log_contents=$(cat "$call_log")
rm -f "$call_log"
eq          "gh is never invoked when the repo can't be derived" "" "$call_log_contents"
contains    "falls back to the PR's own number (same-repo no-op)" "Closes #2401" "$out"
not_contains "never guesses the unrelated issue from a wrong-repo lookup" "Closes #9999" "$out"
contains    "script still exits cleanly" "EXIT_CODE=0" "$out"

# ── Test: #1078 — a hung `gh` call times out instead of blocking forever ───
# The stub sleeps well past a short PR_LOOKUP_TIMEOUT, simulating exactly the
# verified live failure: no error, no output, just silence. The call must be
# bounded — the generator degrades to the PR number and the whole script
# still exits 0, instead of hanging indefinitely.
echo "--- #1078 hung gh call is bounded by PR_LOOKUP_TIMEOUT ---"
out=$(run_test '
  mc "chore: initial"
  git tag v22.0.0
  mc "docs: yet another unscoped change (#2501)"
  git remote add upstream https://github.com/testowner/testrepo.git
  fakebin="$PWD/fakebin"
  make_stub_gh "$fakebin"
  START=$(date +%s)
  PATH="$fakebin:$PATH" STUB_GH_SLEEP=30 PR_LOOKUP_TIMEOUT=2 \
    PREV_TAG="v22.0.0" HEAD_REF="HEAD" VERSION="v22.1.0" DATE="2026-07-30" \
    bash "'"$CHANGELOG_SCRIPT"'" 2>&1
  EXIT_CODE=$?
  END=$(date +%s)
  echo "EXIT_CODE=$EXIT_CODE"
  echo "ELAPSED=$((END - START))"
')
contains "degrades to the PR number when gh hangs" "Closes #2501" "$out"
contains "script still exits cleanly (no hang-induced abort)" "EXIT_CODE=0" "$out"
elapsed=$(echo "$out" | grep -oE 'ELAPSED=[0-9]+' | cut -d= -f2)
if [ -n "$elapsed" ] && [ "$elapsed" -lt 15 ]; then
  echo "  ok: bounded by the timeout, not the 30s sleep (elapsed=${elapsed}s)"
  pass=$((pass + 1))
else
  echo "  FAIL: bounded by the timeout, not the 30s sleep — elapsed=${elapsed}s (expected < 15s)"
  fail=$((fail + 1))
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
if [ "$fail" -eq 0 ]; then
  echo "All $pass test(s) passed."
  exit 0
else
  echo "$fail test(s) FAILED (${pass} passed)."
  exit 1
fi

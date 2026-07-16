#!/bin/bash
# Hermetic smoke test for bin/conformance-publish-badge.sh (#871).
#
# Exercises the real script end-to-end against:
#   - a local bare git repo standing in for the GitHub remote (no network)
#   - a stubbed `gh` on PATH returning synthetic `actions/runs/.../jobs` JSON
#
# What this proves:
#   1. First run, all three harnesses green -> streak 1/1/1, brightgreen badges.
#   2. Second run, opencode green / pi red / codex green -> opencode streak 2,
#      pi streak RESET to 0 (red badge), codex streak 2.
#   3. Third run all green -> opencode + codex reach the green-continuous
#      threshold (3) and their badge message says "(proven)"; pi is back
#      to streak 1 (not proven) because run 2 reset it.
#   4. Cursor's badge is seeded once as a static grey "documented-manual"
#      badge and is NEVER touched by a later run (no matrix job drives it).
#   5. The conformance-badge branch is an orphan (no shared history with
#      the default branch) — verified by `git merge-base` failing.
#   6. Dispatch-path streak guard (me2resh/apexyard#880): a `workflow_dispatch`
#      run — even one where every matrix job reports "success" (the
#      strongest form of the regression: a single-harness dispatch leaves
#      the two non-selected jobs reporting a trivial skip-success) — leaves
#      every harness's streak file AND badge JSON byte-for-byte untouched,
#      and produces no new commit on the conformance-badge branch.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PUBLISHER="$ROOT/bin/conformance-publish-badge.sh"

PASS=0
FAIL=0
FAILED_CASES=""

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $desc (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n  - $desc (expected to contain '$needle', got: $haystack)" ;;
  esac
}

[ -f "$PUBLISHER" ] || { echo "FATAL: publisher script not found: $PUBLISHER"; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Fixture: a bare "GitHub remote" repo with an initial commit on main.
# ---------------------------------------------------------------------------
REMOTE="$TMPDIR/remote.git"
git init --quiet --bare "$REMOTE"

SEED="$TMPDIR/seed"
git init --quiet "$SEED"
(
  cd "$SEED" || exit 1
  git config user.email "seed@apexyard.test"
  git config user.name "seed"
  git checkout --quiet -b main
  echo "seed" > README.md
  git add README.md
  git commit --quiet -m "seed"
  git remote add origin "$REMOTE"
  git push --quiet origin main
)

# ---------------------------------------------------------------------------
# Stub `gh` on PATH: `gh api repos/.../actions/runs/<id>/jobs --paginate`
# returns synthetic job JSON read from $STUB_JOBS_FILE; `gh` is otherwise
# unused by the publisher (git push uses a token-embedded https URL, not
# the gh CLI), so this stub only needs to answer the one subcommand.
# ---------------------------------------------------------------------------
STUB_BIN="$TMPDIR/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "api" ]; then
  cat "$STUB_JOBS_FILE"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/gh"

jobs_json_for() {
  # $1=opencode conclusion $2=pi conclusion $3=codex conclusion
  cat <<JSON
{
  "jobs": [
    {"name": "conformance / opencode", "conclusion": "$1"},
    {"name": "conformance / pi", "conclusion": "$2"},
    {"name": "conformance / codex", "conclusion": "$3"}
  ]
}
JSON
}

# The publisher clones "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
# — point REPO resolution at our local bare repo via a git insteadOf rewrite
# so no network call happens and no real GH_TOKEN is needed.
export HOME="$TMPDIR/home"
mkdir -p "$HOME"
git config --global "url.$REMOTE.insteadOf" "https://x-access-token:test-token@github.com/apexyard-test/conformance-fixture.git"
git config --global user.email "conformance-ci@apexyard.test"
git config --global user.name "apexyard-conformance-ci"

run_publisher() {
  local run_id="$1" o="$2" p="$3" c="$4" event="${5:-schedule}"
  STUB_JOBS_FILE="$TMPDIR/jobs-$run_id.json"
  jobs_json_for "$o" "$p" "$c" > "$STUB_JOBS_FILE"
  PATH="$STUB_BIN:$PATH" \
    GH_TOKEN="test-token" \
    RUN_ID="$run_id" \
    REPO="apexyard-test/conformance-fixture" \
    EVENT_NAME="$event" \
    STUB_JOBS_FILE="$STUB_JOBS_FILE" \
    bash "$PUBLISHER" >"$TMPDIR/publisher-$run_id.log" 2>&1
}

read_badge_branch_file() {
  local file="$1" out="$TMPDIR/checkout-$RANDOM"
  git clone --quiet -b conformance-badge "$REMOTE" "$out" 2>/dev/null || return 1
  cat "$out/$file" 2>/dev/null
  rm -rf "$out"
}

# --- Run 1: all green ------------------------------------------------------
run_publisher 1001 success success success
opencode_json="$(read_badge_branch_file opencode.json)"
assert_contains "run1: opencode message is 'green'" "$opencode_json" '"message": "green"'
assert_eq "run1: opencode streak file = 1" "1" "$(read_badge_branch_file streak-opencode.txt)"
assert_eq "run1: pi streak file = 1" "1" "$(read_badge_branch_file streak-pi.txt)"
assert_eq "run1: codex streak file = 1" "1" "$(read_badge_branch_file streak-codex.txt)"

cursor_json="$(read_badge_branch_file cursor.json)"
assert_contains "run1: cursor badge seeded as documented-manual" "$cursor_json" "documented-manual"
assert_contains "run1: cursor badge color lightgrey" "$cursor_json" "lightgrey"

# --- Run 2: opencode green, pi red (failure), codex green -----------------
run_publisher 1002 success failure success
assert_eq "run2: opencode streak = 2" "2" "$(read_badge_branch_file streak-opencode.txt)"
assert_eq "run2: pi streak RESET to 0" "0" "$(read_badge_branch_file streak-pi.txt)"
assert_eq "run2: codex streak = 2" "2" "$(read_badge_branch_file streak-codex.txt)"
pi_json="$(read_badge_branch_file pi.json)"
assert_contains "run2: pi badge is red" "$pi_json" '"color": "red"'
assert_contains "run2: pi badge names the failure conclusion" "$pi_json" "failure"

# --- Run 3: all green again -> opencode/codex hit the 3-green threshold ---
run_publisher 1003 success success success
assert_eq "run3: opencode streak = 3" "3" "$(read_badge_branch_file streak-opencode.txt)"
assert_eq "run3: pi streak = 1 (post-reset)" "1" "$(read_badge_branch_file streak-pi.txt)"
assert_eq "run3: codex streak = 3" "3" "$(read_badge_branch_file streak-codex.txt)"

opencode_json3="$(read_badge_branch_file opencode.json)"
assert_contains "run3: opencode badge says proven at streak 3" "$opencode_json3" "(proven)"
pi_json3="$(read_badge_branch_file pi.json)"
assert_contains "run3: pi badge NOT proven (streak only 1)" "$pi_json3" '"message": "green"'
case "$pi_json3" in
  *"(proven)"*) FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n  - run3: pi badge incorrectly says proven at streak 1" ;;
  *) PASS=$((PASS + 1)) ;;
esac

# Cursor untouched across all three runs
cursor_json3="$(read_badge_branch_file cursor.json)"
assert_eq "run3: cursor badge unchanged across runs" "$cursor_json" "$cursor_json3"

# --- Run 4: workflow_dispatch must NOT touch any streak or badge JSON -----
# All three conclusions read "success" here on purpose — this is the
# strongest form of the regression this guard closes. A real single-harness
# dispatch would show one harness's REAL conclusion plus two trivial
# skip-successes (SELECTED=false, exit 0, no gated turn run); collapsing
# that to "all success" proves the guard doesn't cherry-pick which harness
# to protect — EVENT_NAME != 'schedule' must leave every harness alone.
BEFORE_OPENCODE_STREAK="$(read_badge_branch_file streak-opencode.txt)"
BEFORE_PI_STREAK="$(read_badge_branch_file streak-pi.txt)"
BEFORE_CODEX_STREAK="$(read_badge_branch_file streak-codex.txt)"
BEFORE_OPENCODE_JSON="$(read_badge_branch_file opencode.json)"
BEFORE_PI_JSON="$(read_badge_branch_file pi.json)"
BEFORE_CODEX_JSON="$(read_badge_branch_file codex.json)"
BEFORE_BADGE_HEAD="$(git ls-remote "$REMOTE" conformance-badge | cut -f1)"

run_publisher 1004 success success success workflow_dispatch

assert_eq "run4 (dispatch): opencode streak untouched" "$BEFORE_OPENCODE_STREAK" "$(read_badge_branch_file streak-opencode.txt)"
assert_eq "run4 (dispatch): pi streak untouched" "$BEFORE_PI_STREAK" "$(read_badge_branch_file streak-pi.txt)"
assert_eq "run4 (dispatch): codex streak untouched" "$BEFORE_CODEX_STREAK" "$(read_badge_branch_file streak-codex.txt)"
assert_eq "run4 (dispatch): opencode.json untouched" "$BEFORE_OPENCODE_JSON" "$(read_badge_branch_file opencode.json)"
assert_eq "run4 (dispatch): pi.json untouched" "$BEFORE_PI_JSON" "$(read_badge_branch_file pi.json)"
assert_eq "run4 (dispatch): codex.json untouched" "$BEFORE_CODEX_JSON" "$(read_badge_branch_file codex.json)"

AFTER_BADGE_HEAD="$(git ls-remote "$REMOTE" conformance-badge | cut -f1)"
assert_eq "run4 (dispatch): no new commit on conformance-badge branch" "$BEFORE_BADGE_HEAD" "$AFTER_BADGE_HEAD"
assert_contains "run4 (dispatch): publisher log explains the skip" "$(cat "$TMPDIR/publisher-1004.log")" "not 'schedule'"

# --- Orphan-branch check ----------------------------------------------------
CHECKOUT="$TMPDIR/orphan-check"
git clone --quiet "$REMOTE" "$CHECKOUT" 2>/dev/null
(
  cd "$CHECKOUT" || exit 1
  git fetch --quiet origin conformance-badge:conformance-badge 2>/dev/null
  if git merge-base main conformance-badge >/dev/null 2>&1; then
    echo "NOT_ORPHAN"
  else
    echo "ORPHAN"
  fi
) > "$TMPDIR/orphan-result.txt"
assert_eq "conformance-badge branch has no shared history with main (orphan)" "ORPHAN" "$(cat "$TMPDIR/orphan-result.txt")"

echo ""
echo "test_conformance_publish_badge.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  echo ""
  echo "--- publisher logs (for debugging) ---"
  cat "$TMPDIR"/publisher-*.log 2>/dev/null
  exit 1
fi
exit 0

#!/bin/bash
# Hermetic smoke test for bin/conformance-publish-badge.sh (#871).
#
# Exercises the real script end-to-end against:
#   - a local bare git repo standing in for the GitHub remote (no network)
#   - a stubbed `gh` on PATH returning synthetic `actions/runs/.../jobs` JSON
#
# Scheduled opencode results advance or reset its streak.
# Pi and codex keep stored streaks and show grey manual badges.
# Missing jobs do not create streak files for manual harnesses.
# Dispatch leaves every streak and badge unchanged (#880).
# Cursor stays manual. The badge branch stays orphaned.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


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
  # An empty pi conclusion represents a schedule with only opencode.
  if [ -z "$2" ]; then
    printf '{"jobs":[{"name":"conformance / opencode","conclusion":"%s"}]}' "$1"
    return
  fi
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
# -- point REPO resolution at our local bare repo via a git insteadOf rewrite
# so no network call happens and no real GH_TOKEN is needed.
#
# Snapshot BOTH real global-config candidates BEFORE overwriting HOME
# (me2resh/apexyard#1526). When XDG_CONFIG_HOME is set and ~/.gitconfig is
# absent, `git config --global` writes to $XDG_CONFIG_HOME/git/config -- so
# HOME alone does not sandbox the developer identity.
REAL_DOT_GITCONFIG="$HOME/.gitconfig"
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  REAL_XDG_GITCONFIG="$XDG_CONFIG_HOME/git/config"
else
  REAL_XDG_GITCONFIG="$HOME/.config/git/config"
fi
# Resolve to absolute paths while HOME / XDG_CONFIG_HOME still point at the
# real locations (after `export HOME=...` relative expansion would be wrong).
case "$REAL_DOT_GITCONFIG" in
  /*) ;;
  *) REAL_DOT_GITCONFIG="$(pwd)/$REAL_DOT_GITCONFIG" ;;
esac
case "$REAL_XDG_GITCONFIG" in
  /*) ;;
  *) REAL_XDG_GITCONFIG="$(pwd)/$REAL_XDG_GITCONFIG" ;;
esac
if [ -f "$REAL_DOT_GITCONFIG" ]; then
  REAL_DOT_GITCONFIG_EXISTED=1
  REAL_DOT_GITCONFIG_CKSUM="$(cksum < "$REAL_DOT_GITCONFIG")"
else
  REAL_DOT_GITCONFIG_EXISTED=0
  REAL_DOT_GITCONFIG_CKSUM=""
fi
if [ -f "$REAL_XDG_GITCONFIG" ]; then
  REAL_XDG_GITCONFIG_EXISTED=1
  REAL_XDG_GITCONFIG_CKSUM="$(cksum < "$REAL_XDG_GITCONFIG")"
else
  REAL_XDG_GITCONFIG_EXISTED=0
  REAL_XDG_GITCONFIG_CKSUM=""
fi

# Explicit sandbox: HOME + unset XDG_CONFIG_HOME + GIT_CONFIG_GLOBAL so
# `git config --global` cannot land in the developer's XDG config. The
# regression case below calls this same function, so it tests this code.
sandbox_git_global() {
  export HOME="$1"
  unset XDG_CONFIG_HOME
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
}
sandbox_git_global "$TMPDIR/home"
git config --global "url.$REMOTE.insteadOf" "https://x-access-token:test-token@github.com/apexyard-test/conformance-fixture.git"
git config --global user.email "conformance-ci@apexyard.test"
git config --global user.name "apexyard-conformance-ci"

# Regression (#1526): prove the guard keeps a seeded XDG git/config intact.
# If sandbox_git_global only set HOME (the pre-#1526 behaviour), the seeded
# user.email would be overwritten and this case fails. Checked by reducing the
# function body to `export HOME="$1"; mkdir -p "$HOME"`.
REG_XDG="$(mktemp -d)"
mkdir -p "$REG_XDG/git"
cat > "$REG_XDG/git/config" <<'SEED'
[user]
	email = seeded-xdg@apexyard.test
SEED
REG_XDG_CKSUM_BEFORE="$(cksum < "$REG_XDG/git/config")"
(
  export XDG_CONFIG_HOME="$REG_XDG"
  sandbox_git_global "$TMPDIR/home-xdg-regression"
  git config --global user.email "conformance-ci@apexyard.test"
  git config --global user.name "apexyard-conformance-ci"
)
REG_XDG_CKSUM_AFTER="$(cksum < "$REG_XDG/git/config")"
assert_eq "regression(#1526): seeded XDG git/config byte-identical after sandboxed git config --global" \
  "$REG_XDG_CKSUM_BEFORE" "$REG_XDG_CKSUM_AFTER"
rm -rf "$REG_XDG"

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
for harness in pi codex; do
  assert_eq "run1: $harness has no streak file" "" "$(read_badge_branch_file streak-$harness.txt)"
  manual_json="$(read_badge_branch_file "$harness.json")"
  assert_eq "run1: $harness endpoint schema" "1" "$(printf '%s' "$manual_json" | jq -r .schemaVersion)"
  assert_eq "run1: $harness endpoint label" "conformance: $harness" "$(printf '%s' "$manual_json" | jq -r .label)"
  assert_contains "run1: $harness badge is manual" "$manual_json" '"message": "manual"'
  assert_contains "run1: $harness badge is grey" "$manual_json" '"color": "lightgrey"'
done

# Seed stored streaks from the previous schedule design.
STORED="$TMPDIR/stored-streaks"
git clone --quiet -b conformance-badge "$REMOTE" "$STORED"
printf '7\n' > "$STORED/streak-pi.txt"
printf '5\n' > "$STORED/streak-codex.txt"
git -C "$STORED" add streak-pi.txt streak-codex.txt
git -C "$STORED" commit --quiet -m 'seed stored streaks'
git -C "$STORED" push --quiet origin conformance-badge

cursor_json="$(read_badge_branch_file cursor.json)"
assert_contains "run1: cursor badge seeded as documented-manual" "$cursor_json" "documented-manual"
assert_contains "run1: cursor badge color lightgrey" "$cursor_json" "lightgrey"

# --- Run 2: only opencode has a job ---------------------------------------
# An empty pi conclusion makes the fixture omit both manual jobs.
run_publisher 1002 success '' ''
assert_eq "run2: opencode streak = 2" "2" "$(read_badge_branch_file streak-opencode.txt)"
for harness in pi codex; do
  assert_eq "run2: $harness stored streak byte-identical" \
    "$(cksum < "$STORED/streak-$harness.txt")" \
    "$(git --git-dir="$REMOTE" show "conformance-badge:streak-$harness.txt" | cksum)"
  manual_json="$(read_badge_branch_file "$harness.json")"
  assert_contains "run2: $harness badge is manual" "$manual_json" '"message": "manual"'
  assert_contains "run2: $harness badge is grey" "$manual_json" '"color": "lightgrey"'
done

# --- Run 3: another green opencode reaches the threshold -------------------
run_publisher 1003 success '' ''
assert_eq "run3: opencode streak = 3" "3" "$(read_badge_branch_file streak-opencode.txt)"
opencode_json3="$(read_badge_branch_file opencode.json)"
assert_contains "run3: opencode badge says proven at streak 3" "$opencode_json3" "(proven)"

# A red opencode resets only its own streak.
run_publisher 1005 failure '' ''
assert_eq "red opencode resets streak" "0" "$(read_badge_branch_file streak-opencode.txt)"
assert_contains "red opencode badge names failure" "$(read_badge_branch_file opencode.json)" 'red (failure)'
assert_contains "red opencode badge is red" "$(read_badge_branch_file opencode.json)" '"color": "red"'
assert_eq "red opencode leaves pi streak" "7" "$(read_badge_branch_file streak-pi.txt)"
assert_eq "red opencode leaves codex streak" "5" "$(read_badge_branch_file streak-codex.txt)"
for harness in pi codex; do
  assert_contains "red opencode leaves $harness manual" "$(read_badge_branch_file "$harness.json")" '"message": "manual"'
done

# Cursor untouched across all three runs
cursor_json3="$(read_badge_branch_file cursor.json)"
assert_eq "run3: cursor badge unchanged across runs" "$cursor_json" "$cursor_json3"

# --- Run 4: workflow_dispatch must NOT touch any streak or badge JSON -----
# All three conclusions read "success" here on purpose -- this is the
# strongest form of the regression this guard closes. A real single-harness
# dispatch would show one harness's REAL conclusion plus two trivial
# skip-successes (SELECTED=false, exit 0, no gated turn run); collapsing
# that to "all success" proves the guard doesn't cherry-pick which harness
# to protect -- EVENT_NAME != 'schedule' must leave every harness alone.
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

# --- Real global git-config integrity (#1526) -------------------------------
# Always run these (assert_* never exits) so an earlier failure cannot mask
# clobbering of the developer's ~/.gitconfig or XDG git/config.
if [ "$REAL_DOT_GITCONFIG_EXISTED" -eq 1 ]; then
  assert_eq "real ~/.gitconfig cksum unchanged" \
    "$REAL_DOT_GITCONFIG_CKSUM" "$(cksum < "$REAL_DOT_GITCONFIG")"
else
  if [ -f "$REAL_DOT_GITCONFIG" ]; then
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - real ~/.gitconfig must still be absent (was created by this test)"
  else
    PASS=$((PASS + 1))
  fi
fi
if [ "$REAL_XDG_GITCONFIG_EXISTED" -eq 1 ]; then
  assert_eq "real XDG git/config cksum unchanged" \
    "$REAL_XDG_GITCONFIG_CKSUM" "$(cksum < "$REAL_XDG_GITCONFIG")"
else
  if [ -f "$REAL_XDG_GITCONFIG" ]; then
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - real XDG git/config must still be absent (was created by this test)"
  else
    PASS=$((PASS + 1))
  fi
fi

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

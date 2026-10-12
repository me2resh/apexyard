#!/bin/bash
# Test the read-only approval checks with a stub forge.
set -u
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$SRC_ROOT/.claude/skills/approve-merge/scripts/approve-merge.sh"
PASS=0 FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
if [ ! -x "$SCRIPT" ]; then
  fail 'executable script exists'
  exit 1
fi
if grep -qE 'gh pr merge|glab mr merge|tracker_pr_merge|approved_by|>[^;]*session/reviews' "$SCRIPT"; then
  fail 'script has no merge command or marker write'
else
  pass 'script has no merge command or marker write'
fi
SB=$(mktemp -d "$SRC_ROOT/.approve-merge-test.XXXXXX") || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/.claude/hooks" "$SB/.claude/session/reviews" "$SB/bin"
touch "$SB/.apexyard-fork"
cp "$SRC_ROOT/.claude/hooks/"_lib-*.sh "$SB/.claude/hooks/"
cp "$SRC_ROOT/.claude/project-config.defaults.json" "$SB/.claude/"
cat > "$SB/bin/gh" <<'GH'
#!/bin/bash
set -u
case "$*" in
  *'--json state,'*) jq -cn --arg state "$TEST_STATE" '{state:$state,isDraft:false,mergeable:"MERGEABLE",headRefOid:"abc123",mergeStateStatus:"CLEAN",baseRefName:"dev"}' ;;
  *'--json url,baseRefName'*) echo 'https://github.com/owner/repo/pull/42' ;;
  *'--json headRefName'*) printf '%s\n' "$TEST_BRANCH" ;;
  *'--json title'*) printf '%s\n' "$TEST_TITLE" ;;
  *'--json body'*) [ "$TEST_BODY" != READ_ERROR ] || exit 1; printf '%s' "$TEST_BODY" ;;
  *'.behind_by'*) printf '%s\n' "$TEST_BEHIND" ;;
  *'.merge_base_commit.sha'*) echo base123 ;;
  *) exit 1 ;;
esac
GH
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH"
export TEST_STATE=OPEN TEST_BRANCH=feature/example TEST_TITLE='feat(#42): example' TEST_BODY='Released-From: abc123' TEST_BEHIND=0
MARKER="$SB/.claude/session/reviews/owner__repo__42-rex.approved"
# Start with no markers. A missing review must not create one.
before=$(ls -a "$SB/.claude/session/reviews")
run() {
  bash "$SCRIPT" 42 owner/repo "$SB" > "$SB/out" 2> "$SB/err"
  RC=$?
}
expect_code() {
  run
  if [ "$RC" -eq "$2" ] && { [ "$2" -eq 0 ] || [ ! -s "$SB/out" ]; }; then pass "$1"; else fail "$1 (exit $RC)"; fi
}
expect_code 'missing marker' 12
after=$(ls -a "$SB/.claude/session/reviews")
[ "$before" = "$after" ] && pass 'missing marker leaves empty directory unchanged' || fail 'missing marker changed directory'
printf '%s\n' abc123 > "$MARKER"
before=$(ls -a "$SB/.claude/session/reviews"; cksum "$MARKER")
expect_code 'normal PR' 0
if [ "$(wc -l < "$SB/out" | tr -d ' ')" = 1 ] && jq -e --arg home "$SB" '.marker_home == $home and .pr_host_repo == "owner/repo" and .strategy == "squash" and .release_class == false and .head_sha == "abc123" and length == 5' "$SB/out" >/dev/null; then
  pass 'normal PR prints one compact JSON result'
else
  fail 'normal PR JSON result'
fi
after=$(ls -a "$SB/.claude/session/reviews"; cksum "$MARKER")
[ "$before" = "$after" ] && pass 'normal PR leaves markers unchanged' || fail 'normal PR changed markers'
TEST_BRANCH=sync/main-to-dev-after-v1.0.0
expect_code 'sync PR' 0
jq -e '.strategy == "merge"' "$SB/out" >/dev/null && pass 'sync strategy' || fail 'sync strategy'
TEST_BRANCH=release/v1.2.3
expect_code 'release PR' 0
jq -e '.release_class == true and .strategy == "squash"' "$SB/out" >/dev/null && pass 'release classification' || fail 'release classification'
TEST_BODY=''
expect_code 'release empty body' 13
TEST_BODY=READ_ERROR
expect_code 'release unreadable body' 13
TEST_TITLE=''
expect_code 'release empty title' 13
TEST_TITLE='feat(#42): example' TEST_BRANCH=feature/example TEST_STATE=CLOSED
expect_code 'closed PR' 1
TEST_STATE=OPEN
printf '%s\n' stale > "$MARKER"
# Stub graph checks for deterministic carry-over and refresh outcomes.
cat > "$SB/.claude/hooks/_lib-merge-behind.sh" <<'LIB'
is_pr_behind_base() { printf '%s\n' "$TEST_GRAPH"; }
merge_refresh_required() { printf '%s\n' "$TEST_REFRESH"; }
rex_approval_carries_over() { printf '%s\n' "$TEST_CARRY"; }
LIB
export TEST_GRAPH=false TEST_REFRESH=required TEST_CARRY=false
expect_code 'stale Rex marker' 12
TEST_CARRY=unknown
expect_code 'unknown carry-over' 12
TEST_CARRY=true
expect_code 'verified carry-over' 0
rm "$MARKER"
printf '%s\n' abc123 > "$SB/.claude/session/reviews/42-rex.approved"
expect_code 'near-miss marker' 12
grep -q 'do not move, rename or copy' "$SB/err" && pass 'near-miss recovery guidance' || fail 'near-miss recovery guidance'
printf '%s\n' abc123 > "$MARKER"
TEST_GRAPH=true
expect_code 'behind PR requires refresh' 10
grep -q 'behind its base' "$SB/err" && pass 'behind-base explanation' || fail 'behind-base explanation'
TEST_REFRESH=skippable
expect_code 'unrelated base changes skip refresh' 0
TEST_GRAPH=unknown
expect_code 'unknown behind-base state' 11
TEST_GRAPH=''
expect_code 'empty behind-base state' 11
printf '%s\n' '{"merge":{"require_up_to_date":false}}' > "$SB/.claude/project-config.json"
expect_code 'explicit false disables behind check' 0
printf 'Passed: %s\nFailed: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

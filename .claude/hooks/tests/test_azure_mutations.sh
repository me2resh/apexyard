#!/bin/bash
# shellcheck disable=SC2016 # Hostile text is deliberately literal test data.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=/dev/null
AZURE_FIXTURE_ONLY=1 . "$ROOT/.claude/hooks/tests/test_tracker_azure.sh"
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
cp "$ROOT/.claude/hooks/_lib-azure.sh" "$SB/_lib-azure.sh"
for gate in block-unreviewed-merge.sh block-merge-on-red-ci.sh require-design-review-for-ui.sh require-architecture-review.sh; do
  cat > "$SB/$gate" <<'SH'
#!/bin/bash
name=${0##*/}
cat >/dev/null
printf '%s\n' "$name" >> "$AZ_GATE_LOG"
[ "${AZ_GATE_FAIL:-}" != "$name" ] || exit 2
if [ "$name" = require-architecture-review.sh ] && [ "${AZ_RACE:-0}" = 1 ]; then
  printf '%s\n' "$OLD_SHA" > "$AZ_HEAD_FILE"
fi
SH
done
# shellcheck source=/dev/null
. "$SB/_lib-azure.sh"
export AZ_PAYLOAD="$SB/payload.json" AZ_WRITES="$SB/writes" AZ_GATE_LOG="$SB/gates" AZ_HEAD_FILE="$SB/head" OLD_SHA
printf 'literal $(touch nope); quote " text\n' > "$SB/body"
reset_case() {
  printf '%s\n' "$TEST_SHA" > "$AZ_HEAD_FILE"
  : > "$AZ_WRITES"
  : > "$AZ_GATE_LOG"
  rm -f "$AZ_PAYLOAD"
}
merged() {
  reset_case
  local result
  result=$(_azure_merge azure/service 7 squash true 'Merge subject' "$SB/body") || return 1
  printf '%s' "$result" | jq -e --arg sha "$OLD_SHA" '.sha == $sha' >/dev/null || return 1
  [ "$(wc -l < "$AZ_GATE_LOG" | tr -d ' ')" = 4 ] || return 1
  jq -e --arg sha "$TEST_SHA" '.lastMergeSourceCommit.commitId == $sha and .completionOptions.bypassPolicy == false and .completionOptions.mergeStrategy == "squash" and (.completionOptions.mergeCommitMessage | contains("$(touch nope)"))' "$AZ_PAYLOAD" >/dev/null
}
blocked_gate() {
  reset_case
  ! AZ_GATE_FAIL=block-merge-on-red-ci.sh _azure_merge azure/service 7 squash true >/dev/null || return 1
  [ ! -e "$AZ_PAYLOAD" ] && [ ! -s "$AZ_WRITES" ]
}
source_race() {
  reset_case
  ! AZ_RACE=1 _azure_merge azure/service 7 squash true >/dev/null || return 1
  [ ! -e "$AZ_PAYLOAD" ] && [ ! -s "$AZ_WRITES" ]
}
uncertain_write() {
  reset_case
  ! AZ_WRITE_FAIL=1 _azure_merge azure/service 7 squash true >/dev/null || return 1
  [ "$(wc -l < "$AZ_WRITES" | tr -d ' ')" = 1 ]
}
review_literal() {
  reset_case
  _azure_review azure/service 7 comment "$SB/body" >/dev/null || return 1
  jq -e '.comments[0].content == "literal $(touch nope); quote \" text" and .pullRequestThreadContext.iterationContext.secondComparingIteration == 2' "$AZ_PAYLOAD" >/dev/null
}
create_pr() {
  reset_case
  _azure_create_pr azure/service 'feat(AB-42): example' "$SB/body" main feature/AB-42-example |
    jq -e '.number == 8 and (.url|endswith("/pullrequest/8"))' >/dev/null
}
PASS=0 FAIL=0
check merged
check blocked_gate
check source_race
check uncertain_write
check review_literal
check create_pr
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

#!/bin/bash
# Tests for block-reviewer-ci-wait.sh (me2resh/apexyard#1625).
# A review agent never waits for CI. The orchestrator is never blocked.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-ci-wait.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/session" "$TMP/.claude/hooks"
touch "$TMP/.apexyard-fork"
git -C "$TMP" init -q
cp "$SRC_ROOT/.claude/hooks/block-reviewer-ci-wait.sh" "$TMP/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-review-markers.sh" "$TMP/.claude/hooks/"
cp "$SRC_ROOT/.claude/hooks/_lib-command-scrub.sh" "$TMP/.claude/hooks/"
HOOK="$TMP/.claude/hooks/block-reviewer-ci-wait.sh"

fail=0
SEQ=0

# run_case NAME EXPECTED COMMAND [AGENT_TYPE] [AGENT_ID] [SESSION]
# Each case gets its own session id unless one is given, so the per-run
# counter of one case never leaks into the next.
run_case() {
  local name="$1" expected="$2" command="$3" atype="${4:-}" aid="${5:-}" sid="${6:-}" input out rc
  SEQ=$((SEQ + 1))
  [ -n "$sid" ] || sid="case-$SEQ"
  input=$(jq -cn --arg c "$command" --arg t "$atype" --arg i "$aid" --arg s "$sid" \
    '{session_id:$s,tool_input:{command:$c}} + (if $t != "" then {agent_type:$t} else {} end) + (if $i != "" then {agent_id:$i} else {} end)')
  out=$(cd "$TMP" && printf '%s' "$input" | CLAUDE_CODE_SESSION_ID="$sid" APEXYARD_REVIEW_OPS_ROOT="$TMP" "$HOOK" 2>&1)
  rc=$?
  if [ "$expected" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'BLOCKED:'; then
    echo "PASS: $name"
  elif [ "$expected" = allowed ] && [ "$rc" -eq 0 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (rc=$rc, want $expected): $out" >&2
    fail=1
  fi
}

# Typed review agents: every blocked command is blocked. Each agent gets its
# own agent_id so the per-run counter starts at zero.
for agent in code-reviewer security-reviewer solution-architect; do
  run_case "$agent: gh pr checks --watch" blocked 'gh pr checks 42 --watch' "$agent" "id-$agent-1"
  run_case "$agent: gh run watch" blocked 'gh run watch 123' "$agent" "id-$agent-1"
  run_case "$agent: sleep 60" blocked 'sleep 60' "$agent" "id-$agent-1"
  run_case "$agent: sleep 5m" blocked 'sleep 5m' "$agent" "id-$agent-1"
  run_case "$agent: sleep chained after a command" blocked 'echo x && sleep 120' "$agent" "id-$agent-1"
  run_case "$agent: sleep 30" allowed 'sleep 30' "$agent" "id-$agent-1"
  run_case "$agent: sleep 59" allowed 'sleep 59' "$agent" "id-$agent-1"
  run_case "$agent: unrelated command" allowed 'git log --oneline -3' "$agent" "id-$agent-1"
  run_case "$agent: a single gh pr checks" allowed 'gh pr checks 42' "$agent" "id-$agent-1"
done

# A second gh pr checks in one review run (same session and agent_id).
run_case "reviewer: first gh pr checks" allowed 'gh pr checks 42' code-reviewer run-a sess-two
run_case "reviewer: second gh pr checks, same run" blocked 'gh pr checks 42' code-reviewer run-a sess-two
run_case "reviewer: two gh pr checks in one command" blocked 'gh pr checks 42; gh pr checks 42' code-reviewer run-b sess-three
run_case "reviewer: new run starts at zero" allowed 'gh pr checks 42' code-reviewer run-c sess-two

# Mandatory (Rex B1 on #1622): the orchestrator has no agent identity and is
# never blocked, whatever the command.
run_case "orchestrator: gh pr checks --watch" allowed 'gh pr checks 42 --watch'
run_case "orchestrator: gh run watch" allowed 'gh run watch 123'
run_case "orchestrator: sleep 300" allowed 'sleep 300'
run_case "orchestrator: gh pr checks, first call" allowed 'gh pr checks 42' "" "" same-sess
run_case "orchestrator: gh pr checks, second call" allowed 'gh pr checks 42' "" "" same-sess
run_case "orchestrator: gh pr checks, third call" allowed 'gh pr checks 42' "" "" same-sess

# Another sub-agent type is not a review agent.
run_case "build agent: gh pr checks --watch" allowed 'gh pr checks 42 --watch' backend-engineer id2
run_case "build agent: sleep 300" allowed 'sleep 300' platform-engineer id3

# Sub-agent with an id and no type: the active-reviewer marker decides.
run_case "untyped sub-agent, no marker: sleep 300" allowed 'sleep 300' "" id4 sess-untyped
marker=$(
  # shellcheck disable=SC1091
  . "$TMP/.claude/hooks/_lib-review-markers.sh"
  active_reviewer_marker_path "$TMP" sess-untyped
)
mkdir -p "$(dirname "$marker")"
printf '%s\n' 'acme/app#1:rex' > "$marker"
run_case "untyped sub-agent, marker present: sleep 300" blocked 'sleep 300' "" id4 sess-untyped
run_case "untyped sub-agent, marker present: gh run watch" blocked 'gh run watch 9' "" id4 sess-untyped
run_case "orchestrator with marker present: sleep 300" allowed 'sleep 300' "" "" sess-untyped
rm -f "$marker"
run_case "untyped sub-agent, marker cleared: sleep 300" allowed 'sleep 300' "" id4 sess-untyped

# Quoted data that only mentions a watch command is not a command.
run_case "reviewer: quoted mention in echo" allowed "echo 'gh run watch is banned'" code-reviewer id5

exit "$fail"

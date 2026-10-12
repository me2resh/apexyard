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

# Exercise every wait form for each reviewer and the orchestrator.
patterns=(
  'while ! gh pr checks 42; do sleep 30; done'
  'until gh pr checks 42; do sleep 20; done'
  'for i in 1 2 3; do gh pr checks 42; sleep 30; done'
  'for i in 1 2 3; do sleep 5; done'
  'while gh pr checks 42; do echo x; done'
  'timeout 600 sleep 600' 'timeout -k 5 600 sleep 600'
  'X=1 sleep 600' 'GH_REPO=x gh pr checks 42 --watch'
  'env X=1 sleep 600' 'command sleep 90' 'nohup sleep 90'
  'nice -n 5 sleep 90' 'exec sleep 90' 'time sleep 90'
  '/bin/sleep 90' '/usr/bin/env sleep 90' '/usr/local/bin/gh run watch 1'
  'bash -c "sleep 600"' "sh -c 'gh run watch 1'"
  'bash -lc "gh pr checks 42 --watch"' 'bash -c "echo x; sleep 600"'
  'eval "sleep 600"' '(sleep 90)' '{ sleep 90; }'
  "echo \$(sleep 90)" "echo \`sleep 90\`"
  'sleep 1e9' 'sleep 1e2' 'sleep 0x100' 'sleep 090' 'sleep 0090'
  'sleep 30 && sleep 30' 'gh  pr  checks 42 --watch'
  $'gh\tpr\tchecks 42 --watch'
)
for pattern in "${patterns[@]}"; do
  for agent in code-reviewer security-reviewer solution-architect; do
    run_case "$agent: $pattern" blocked "$pattern" "$agent"
  done
  run_case "orchestrator: $pattern" allowed "$pattern"
done
for agent in code-reviewer security-reviewer solution-architect; do
  for pattern in 'sleep 08' "for f in a b; do echo \$f; done" 'timeout 30 sleep 30' '/bin/sleep 5' 'bash -c "echo hi"' '(echo hi)' 'sleep 30'; do
    run_case "$agent: $pattern" allowed "$pattern" "$agent"
  done
done
for pattern in 'sleep 30 && sleep 30' 'bash -c "sleep 600"' 'for i in 1 2; do sleep 5; done'; do
  run_case "build agent: $pattern" allowed "$pattern" backend-engineer
done

# AC2: 090 and 0090 are decimal 90 and blocked. 08 is decimal 8 and allowed.
# Exercise both sides of each regression for reviewers and exempt callers.
blocked_regressions=(
  'sleep 9e1' 'sleep 600e-1' 'sleep 5.91e1' 'sleep 599e-1'
  'sleep 1e999999999999999999999' 'sleep 0.1e999999999999999999999'
  'sleep 9223372036854775808' 'sleep 18446744073709551616'
  'sleep 999999999999999999999999999999999999m'
  'sleep 0x8000000000000000' 'sleep 090' 'sleep 0090'
  'sleep 00000000000000000000000000000090'
  'while true; do gh pr checks 42; done'
  'for f in a b; do echo x; sleep 1; done'
  'for f in a b; do for g in c d; do echo x; done; sleep 1; done'
  'for f in a b; do echo x; done; while true; do sleep 1; done'
  'for x in a b; { sleep 30; }; sleep 100'
  'for x in $(sleep 100); do echo; done'
  'for x in a b; { sleep 30; }'
  'for x in $(sleep 30 && sleep 30); do echo; done'
  'for x in $(gh pr checks 42); do echo; done; gh pr checks 42'
  'while true; do for x in $(sleep 1); do echo; done; done'
)
allowed_regressions=(
  'sleep 5e1' 'sleep 590e-1' 'sleep 5.8e1' 'sleep 1e-2'
  'sleep 0e999999999999999999999' 'sleep 1e+00000000000000000001'
  'sleep 00000000000000000000000000000008' 'sleep 0x00000008'
  'sleep 08' 'sleep 009' 'sleep 0'
  'gh pr checks 42 | while read l; do echo "$l"; done'
  'for f in a b; do echo "$f"; done; sleep 1'
  'while read l; do echo "$l"; done; gh pr checks 42'
  'sleep 1; for f in a b; do echo "$f"; done'
  'for f in a b; do for g in c d; do echo x; done; done; sleep 1'
  'for f in a b; do echo x; done; gh pr checks 42'
  'for x in $(sleep 5); do echo; done'
  'for x in $(gh pr checks 42); do echo; done'
  'for x in a b; { echo x; }'
)
for pattern in "${blocked_regressions[@]}"; do
  for agent in code-reviewer security-reviewer solution-architect; do
    run_case "$agent regression: $pattern" blocked "$pattern" "$agent"
  done
  run_case "orchestrator regression: $pattern" allowed "$pattern"
  run_case "build agent regression: $pattern" allowed "$pattern" backend-engineer
done
for pattern in "${allowed_regressions[@]}"; do
  for agent in code-reviewer security-reviewer solution-architect; do
    run_case "$agent regression: $pattern" allowed "$pattern" "$agent"
  done
  run_case "orchestrator regression: $pattern" allowed "$pattern"
  run_case "build agent regression: $pattern" allowed "$pattern" backend-engineer
done

assert_result() {
  if "$@"; then
    echo "PASS: $CHECK_NAME"
  else
    echo "FAIL: $CHECK_NAME" >&2
    fail=1
  fi
}
input='{"agent_type":"code-reviewer","tool_input":{"command":"sleep 08"}}'
out=$(printf '%s' "$input" | "$HOOK" 2>&1)
rc=$?
CHECK_NAME='amended AC2: sleep 08 is decimal 8 and allows with clean stderr'
assert_result test "$rc" -eq 0
assert_result test -z "$out"

input='{"session_id":"atomic","agent_type":"code-reviewer","agent_id":"parallel","tool_input":{"command":"gh pr checks 42"}}'
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  (
    printf '%s' "$input" | APEXYARD_REVIEW_OPS_ROOT="$TMP" "$HOOK" >/dev/null 2>&1
    echo "$?" > "$TMP/rc-$i"
  ) &
done
wait
CHECK_NAME='atomic counter allows exactly one call and blocks eleven'
assert_result test "$(grep -l '^0$' "$TMP"/rc-* | wc -l | tr -d ' ')" -eq 1
assert_result test "$(grep -l '^2$' "$TMP"/rc-* | wc -l | tr -d ' ')" -eq 11
counter_dir="$TMP/.claude/session/review-ci-checks"
touch "$counter_dir/old" "$counter_dir/fresh"
touch -t 202001010000 "$counter_dir/old"
run_case 'prune on first check' allowed 'gh pr checks 42' code-reviewer prune prune
CHECK_NAME='pruning removes old counters and keeps fresh counters'
assert_result test ! -e "$counter_dir/old"
assert_result test -f "$counter_dir/fresh"
input='{"agent_type":"code-reviewer","tool_input":{"command":"gh pr checks 42"}}'
for i in 1 2; do
  printf '%s' "$input" | env -u CLAUDE_CODE_SESSION_ID APEXYARD_REVIEW_OPS_ROOT="$TMP" "$HOOK" >/dev/null 2>&1
  rc=$?
  CHECK_NAME="unidentified run call $i allows"
  assert_result test "$rc" -eq 0
done
CHECK_NAME='unidentified run creates no counter'
assert_result test ! -e "$counter_dir/nosession-code-reviewer"

TMP2="$TMP/decoy"
OPS2="$TMP/ops"
mkdir -p "$TMP2/.claude/session" "$OPS2"
touch "$TMP2/.apexyard-fork" "$OPS2/.apexyard-fork"
git -C "$TMP2" init -q
marker=$(
  # shellcheck disable=SC1091
  . "$TMP/.claude/hooks/_lib-review-markers.sh"
  active_reviewer_marker_path "$TMP2" decoy
)
mkdir -p "$(dirname "$marker")"
echo 'acme/app#1:rex' > "$marker"
input='{"session_id":"decoy","agent_id":"untyped","tool_input":{"command":"sleep 300"}}'
(cd "$TMP2" && printf '%s' "$input" | CLAUDE_CODE_SESSION_ID=decoy APEXYARD_REVIEW_OPS_ROOT="$OPS2" "$HOOK")
rc=$?
CHECK_NAME='ops root ignores cwd marker'
assert_result test "$rc" -eq 0
input='{"session_id":"root","agent_type":"code-reviewer","tool_input":{"command":"gh pr checks 42"}}'
for expected in 0 2; do
  (cd "$TMP2" && printf '%s' "$input" | APEXYARD_REVIEW_OPS_ROOT="$OPS2" "$HOOK" >/dev/null 2>&1)
  rc=$?
  CHECK_NAME="ops root counter returns $expected"
  assert_result test "$rc" -eq "$expected"
done
CHECK_NAME='counter lives in supplied root'
assert_result test -f "$OPS2/.claude/session/review-ci-checks/root-code-reviewer"
assert_result test ! -d "$TMP2/.claude/session/review-ci-checks"
input='{"agent_type":"code-reviewer","tool_input":{"command":"sleep 300"}}'
(cd "$TMP2" && printf '%s' "$input" | env -u APEXYARD_REVIEW_OPS_ROOT "$HOOK" >/dev/null 2>&1)
rc=$?
CHECK_NAME='typed reviewer blocks without ops root'
assert_result test "$rc" -eq 2
input='{"session_id":"no-root","agent_type":"code-reviewer","tool_input":{"command":"gh pr checks 42"}}'
for i in 1 2; do
  (cd "$TMP2" && printf '%s' "$input" | env -u APEXYARD_REVIEW_OPS_ROOT "$HOOK" >/dev/null 2>&1)
  rc=$?
  CHECK_NAME="no root check $i allows"
  assert_result test "$rc" -eq 0
done
CHECK_NAME='no root writes no cwd counter'
assert_result test ! -d "$TMP2/.claude/session/review-ci-checks"

REAL_JQ=$(command -v jq)
mkdir -p "$TMP/stub"
cat > "$TMP/stub/jq" <<'STUB'
#!/bin/bash
echo call >> "$JQ_LOG"
exec "$REAL_JQ" "$@"
STUB
chmod +x "$TMP/stub/jq"
export REAL_JQ
export JQ_LOG="$TMP/jq.log"
: > "$JQ_LOG"
input='{"agent_type":"code-reviewer","tool_input":{"command":"git status"}}'
printf '%s' "$input" | PATH="$TMP/stub:$PATH" "$HOOK"
rc=$?
CHECK_NAME='cheap exit never starts jq'
assert_result test "$rc" -eq 0
assert_result test ! -s "$JQ_LOG"
input='{"agent_type":"code-reviewer","tool_input":{"command":"sleep 300"}}'
printf '%s' "$input" | PATH="$TMP/stub:$PATH" "$HOOK" >/dev/null 2>&1
rc=$?
CHECK_NAME='watched command starts jq and blocks'
assert_result test "$rc" -eq 2
assert_result test -s "$JQ_LOG"

printf 'not json sleep 300' | "$HOOK"
rc=$?
CHECK_NAME='malformed JSON allows'
assert_result test "$rc" -eq 0
printf '%s' '{"tool_input":{"command":["sleep","300"]}}' | "$HOOK"
rc=$?
CHECK_NAME='array command allows'
assert_result test "$rc" -eq 0
printf '%s' '{"agent_type":{"a":1},"tool_input":{"command":"sleep 300"}}' | "$HOOK"
rc=$?
CHECK_NAME='object agent type allows'
assert_result test "$rc" -eq 0

exit "$fail"

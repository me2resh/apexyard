#!/bin/bash
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
# shellcheck source=/dev/null
. "$(dirname "$0")/_test-protected-state.sh"
for agent in main platform-engineer code-reviewer; do
  command_text=$(printf 'python3 - <<\047PY\047\nopen(%s, "w").write("x")\nPY\n' "\"$APEXYARD_OPS_PIN_DIR/ops-root-abc\"")
  jq -cn --arg cwd "$TMP/live" --arg command "$command_text" --arg agent "$agent" '{tool_name:"Bash",cwd:$cwd,agent_type:$agent,tool_input:{command:$command}}' > "$TMP/payload"
  check 2 "$agent heredoc pin write" /bin/bash "$ROOT/block-protected-target-writes.sh" < "$TMP/payload"
  command_text=$(printf 'python3 - <<\047PY\047\nprint(1)\nPY\n')
  jq -cn --arg cwd "$TMP/live" --arg command "$command_text" --arg agent "$agent" '{tool_name:"Bash",cwd:$cwd,agent_type:$agent,tool_input:{command:$command}}' > "$TMP/payload"
  check 0 "$agent heredoc read" /bin/bash "$ROOT/block-protected-target-writes.sh" < "$TMP/payload"
done
finish

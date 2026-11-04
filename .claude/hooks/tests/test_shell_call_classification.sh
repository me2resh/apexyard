#!/bin/bash
# GH-1909: Cursor shell shapes must use the same gates as Bash.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_PROJECT_DIR="$TMP/live" CLAUDE_CODE_SESSION_ID=gh1909
export APEXYARD_OPS_PIN_DIR="$TMP/pins"
mkdir -p "$TMP/live/.claude/hooks" "$TMP/live/.git" "$TMP/pins"
touch "$TMP/live/.apexyard-fork" "$TMP/live/.claude/hooks/x.sh"
printf '%s\n' "$TMP/live" > "$TMP/pins/ops-root-gh1909"
PASS=0 FAIL=0
# shellcheck source=/dev/null
. "$ROOT/_lib-fail-closed-json.sh"
check() {
  local want="$1" label="$2" rc=0
  shift 2
  "$@" > "$TMP/out" 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); printf 'FAIL %s expected=%s actual=%s\n' "$label" "$want" "$rc"; cat "$TMP/out"
  fi
}
payload() {
  jq -cn --arg t "$1" --arg c "$2" --arg cwd "$TMP/live" \
    '{tool_name:$t,cwd:$cwd,tool_input:{command:$c}}'
}
gate() { /bin/bash "$ROOT/$1" "${@:3}" <<< "$2"; }
for tool in Bash shellToolCall unknownCursorShell; do
  input=$(payload "$tool" 'echo hi')
  check 0 "$tool classifier" hook_is_shell_call "$input"
  check 0 "$tool protected read" gate block-protected-target-writes.sh "$input"
  check 0 "$tool dispatcher read" gate dispatch-bash.sh "$input"
  input=$(payload "$tool" 'sed -i s/a/b/ .claude/hooks/x.sh')
  check 2 "$tool protected write" gate block-protected-target-writes.sh "$input"
  check 2 "$tool dispatcher write" gate dispatch-bash.sh "$input"
  if [ "$tool" != Bash ]; then
    check 2 "$tool wildcard protected write" gate dispatch-bash.sh "$input" --shell-alias-only
  fi
done
input=$(payload Bash 'sed -i s/a/b/ .claude/hooks/x.sh')
check 0 'wildcard skips Bash already handled by original matcher' gate dispatch-bash.sh "$input" --shell-alias-only
input=$(payload shellToolCall 'echo hi')
check 0 'wildcard Cursor read' gate dispatch-bash.sh "$input" --shell-alias-only
input=$(payload shellToolCall 'sed -i s/a/b/ .claude/hooks/x.sh')
check 2 'wildcard Cursor protected write' gate dispatch-bash.sh "$input" --shell-alias-only
check 2 'named shell with no command' gate block-protected-target-writes.sh '{"tool_name":"shellToolCall","tool_input":{}}'
input=$(payload shellToolCall '')
check 2 'named shell with empty command' gate block-protected-target-writes.sh "$input"
input='{"tool_name":"unknownCursorTool","tool_input":{}}'
check 2 'unknown empty target' gate block-protected-target-writes.sh "$input"
cp "$TMP/out" "$TMP/diagnostic"
check 0 'empty target names tool' grep -q 'missing edit target.*unknownCursorTool' "$TMP/diagnostic"
input=$(jq -cn --arg p "$TMP/live/app.txt" --arg cwd "$TMP/live" \
  '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,command:"echo hi"}}')
check 1 'file target wins fallback' hook_is_shell_call "$input"
check 0 'Write ordinary target' gate block-protected-target-writes.sh "$input"
check 0 'wildcard skips Write' gate dispatch-bash.sh "$input" --shell-alias-only
input=$(jq -cn --arg p "$TMP/live/.claude/hooks/x.sh" --arg cwd "$TMP/live" \
  '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p}}')
check 2 'Write protected target' gate block-protected-target-writes.sh "$input"
for value in null 42 '[]' '""'; do
  input="{\"tool_name\":\"unknown\",\"tool_input\":{\"command\":$value}}"
  check 1 "non-command $value" hook_is_shell_call "$input"
done
# Execute the actual wildcard settings command, so quoting and routing are tested.
command=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "*") | .hooks[].command' "$ROOT/../settings.json")
input=$(payload shellToolCall 'sed -i s/a/b/ .claude/hooks/x.sh')
run_settings() { bash -c "$command" <<< "$input"; }
# The pin points at the fixture. Install the real hooks there for this check.
cp -R "$ROOT/." "$TMP/live/.claude/hooks/"
check 2 'settings wildcard reaches Bash protection' run_settings
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

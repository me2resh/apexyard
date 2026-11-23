#!/bin/bash
set -u
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
PASS=0 FAIL=0
blocked() {
  local command="$1" output rc=0
  output=$(jq -nc --arg command "$command" '{tool_name:"Bash",tool_input:{command:$command}}' |
    bash "$ROOT/.claude/hooks/dispatch-bash.sh" 2>&1) || rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$output" | grep -q 'governed tracker interface'; then
    printf 'PASS blocked %s\n' "$command"; PASS=$((PASS + 1))
  else printf 'FAIL guard %s: rc=%s %s\n' "$command" "$rc" "$output" >&2; FAIL=$((FAIL + 1)); fi
}
blocked 'az repos pr create --auto-complete true --title example'
blocked 'az repos pr create --title example'
blocked 'az repos pr c --auto true'
blocked 'az repos pr update --id 7 --status completed'
blocked 'az repos pr update --id 7 --auto-complete true'
blocked 'az repos pr u --id 7 --bypass-policy true'
blocked 'az devops invoke --area git --resource pullRequests --http-method PATCH --in-file body.json'
blocked 'az devops invoke --area git --resource pullRequests --http-method GET --http-method PATCH'
blocked 'az devops invoke --area git --http-method GET; az repos pr update --status completed'
blocked $'az repos pr \\\nupdate --id 7 --status completed'
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]

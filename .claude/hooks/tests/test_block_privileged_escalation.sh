#!/bin/bash

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/block-privileged-escalation.sh"
PASS=0
FAIL=0

run_case() {
  local name="$1" expected="$2" command="$3" actual
  actual=$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$command" | jq -Rs .)" | "$HOOK" >/tmp/privilege-guard.out 2>/tmp/privilege-guard.err; printf '%s' "$?")
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS [$name]"
    PASS=$((PASS + 1))
  else
    echo "FAIL [$name] expected $expected got $actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

run_case "normal merge" 0 "gh pr merge 12 --squash"
run_case "admin merge" 2 "gh pr merge 12 --squash --admin"
run_case "sudo" 2 "sudo launchctl print system"
run_case "sudo after separator" 2 "echo ready && sudo launchctl print system"
run_case "sudo in argument" 0 "grep sudo README.md"
run_case "force push" 2 "git push --force origin feature/example"
run_case "force-with-lease push" 2 "git push --force-with-lease origin feature/example"
run_case "no verify" 2 "git commit --no-verify -m fix"
run_case "role assumption" 2 "aws sts assume-role --role-arn arn:example"
run_case "normal test" 0 "bash .claude/hooks/tests/test_example.sh"

echo "Privilege escalation guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

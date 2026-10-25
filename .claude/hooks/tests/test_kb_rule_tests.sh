#!/bin/bash
# Static checks for the rule-test contract: /codify-rule, Rex and rule-tests/.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1 — $2"; }

grep -q 'rule-id:' "$REPO_ROOT/.claude/agents/code-reviewer.md" && pass "Rex has rule-id" || fail "Rex has rule-id" ""
grep -q 'rule-tests/' "$REPO_ROOT/.claude/skills/codify-rule/SKILL.md" && pass "codify-rule mentions rule-tests" || fail "codify-rule mentions rule-tests" ""
grep -q '## Must flag' "$REPO_ROOT/.claude/skills/codify-rule/SKILL.md" && pass "codify-rule names the Must flag section" || fail "codify-rule names the Must flag section" ""
[ -f "$REPO_ROOT/rule-tests/README.md" ] && pass "rule-tests README exists" || fail "rule-tests README exists" ""
grep -q 'ENFORCEMENT: blocking' "$REPO_ROOT/.claude/agents/code-reviewer.md" && pass "Rex keeps the ENFORCEMENT marker" || fail "Rex keeps the ENFORCEMENT marker" ""

echo
echo "Total: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]

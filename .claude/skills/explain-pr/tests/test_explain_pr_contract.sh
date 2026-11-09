#!/bin/bash
# test_explain_pr_contract.sh - contract pins for /explain-pr (#1997).
set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKILL_MD="$SRC_ROOT/.claude/skills/explain-pr/SKILL.md"
QUIZ_DOC="$SRC_ROOT/docs/skills/approval-quiz.md"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"

PASS=0
FAIL=0
mark_pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  FAIL: %s\n" "$1" >&2; FAIL=$((FAIL+1)); }

[ -f "$SKILL_MD" ] || { echo "FAIL: missing SKILL.md"; exit 1; }

if ! grep -q '^disable-model-invocation: true$' "$SKILL_MD"; then
  mark_pass "explain-pr is not human-only (no disable-model-invocation: true)"
else
  mark_fail "explain-pr must NOT set disable-model-invocation: true"
fi

if grep -qF 'never writes' "$SKILL_MD" \
  && grep -qF 'AskUserQuestion' "$SKILL_MD" \
  && grep -qF 'approval-quiz.sh' "$SKILL_MD" \
  && grep -qF 'docs/skills/approval-quiz.md' "$SKILL_MD"; then
  mark_pass "explain-pr documents read-only quiz reuse"
else
  mark_fail "explain-pr missing read-only / quiz contract"
fi

if grep -qE 'What changed|Risky parts|Decisions the agent made' "$SKILL_MD"; then
  mark_pass "explain-pr covers what / why / risks / decisions"
else
  mark_fail "explain-pr missing walkthrough sections"
fi

if [ -f "$QUIZ_DOC" ] && grep -qF 'Comprehension check' "$QUIZ_DOC"; then
  mark_pass "shared approval-quiz doc exists"
else
  mark_fail "missing docs/skills/approval-quiz.md"
fi

if grep -qF '| `/explain-pr` |' "$CLAUDE_MD"; then
  mark_pass "CLAUDE.md lists /explain-pr"
else
  mark_fail "CLAUDE.md missing /explain-pr row"
fi

echo
echo "===== test_explain_pr_contract.sh ====="
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0

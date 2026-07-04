#!/bin/bash
# Structural tests for the agent-role-selection rule (me2resh/apexyard#788).
#
# The rule closes a gap role-triggers.md leaves open: role activation is
# defined for in-thread edits/diffs, but nothing maps the Agent-tool spawn
# boundary (subagent_type choice) to a role. Like isolated-builds.md, this
# is a self-discipline rule with no runtime behaviour of its own to
# exercise mechanically (see the rule's own "Backstop" section for why no
# PreToolUse guard shipped alongside it). What we CAN assert mechanically
# is that the artifacts exist and are wired in, so the rule can't silently
# rot:
#
#   1. .claude/rules/agent-role-selection.md exists and carries the
#      ApexYard footer.
#   2. CLAUDE.md imports it via @.claude/rules/agent-role-selection.md.
#   3. CLAUDE.md's rules-count line reads 15 and names "agent role
#      selection".
#
# Test style matches the existing tests/*.sh (e.g. test_isolated_builds.sh)
# — bash + grep, no framework.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE="$SRC_ROOT/.claude/rules/agent-role-selection.md"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"

fail=0
pass() { echo "PASS: $1"; }
die()  { echo "FAIL: $1" >&2; fail=1; }

# 1. Rule file exists + footer
if [ -f "$RULE" ]; then
  pass "rule file exists"
else
  die "rule file missing: $RULE"
fi
if grep -q "Part of \[ApexYard\]" "$RULE" 2>/dev/null; then
  pass "rule file has ApexYard footer"
else
  die "rule file missing the ApexYard footer"
fi

# 2. CLAUDE.md imports the rule
if grep -q '@.claude/rules/agent-role-selection.md' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md imports agent-role-selection.md"
else
  die "CLAUDE.md does not import @.claude/rules/agent-role-selection.md"
fi

# 3. CLAUDE.md rules-count line is present and at least 15 (>= the count as
# of this rule's own PR, #788). Checked as a lower bound, not an exact match,
# so a later rule addition doesn't spuriously fail this test — same pattern
# test_reporting_style.sh established for #783.
RULES_COUNT=$(grep -oE '[0-9]+ modular rule files' "$CLAUDE_MD" 2>/dev/null | grep -oE '^[0-9]+' | head -n 1)
if [ -n "$RULES_COUNT" ] && [ "$RULES_COUNT" -ge 15 ]; then
  pass "CLAUDE.md rules count present and >= 15 (found: $RULES_COUNT)"
else
  die "CLAUDE.md rules-count line missing or below 15 (found: ${RULES_COUNT:-none})"
fi
if grep -qi 'agent role selection' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md rules list names 'agent role selection'"
else
  die "CLAUDE.md rules list does not name 'agent role selection'"
fi

if [ "$fail" -eq 0 ]; then
  echo "All agent-role-selection structural tests passed."
  exit 0
else
  echo "Some agent-role-selection tests FAILED." >&2
  exit 1
fi

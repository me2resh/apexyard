#!/bin/bash
# Structural tests for the isolated-builds rule (me2resh/apexyard#784).
#
# The rule itself is self-discipline (a shell hook can't reliably tell "this
# cd target is a persistent worktree" from "this cd target is a /tmp clone
# that happens to still exist right now"), so there's no runtime behaviour
# to exercise for the rule proper. What we CAN assert mechanically is that
# the artifacts exist and are wired in, so the rule can't silently rot:
#
#   1. .claude/rules/isolated-builds.md exists and carries the ApexYard footer.
#   2. CLAUDE.md imports it via @.claude/rules/isolated-builds.md.
#   3. CLAUDE.md's rules-count line is updated (14) and names "isolated builds".
#
# Test style matches the existing tests/*.sh (e.g. test_reporting_style.sh)
# — bash + grep, no framework.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE="$SRC_ROOT/.claude/rules/isolated-builds.md"
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
if grep -q '@.claude/rules/isolated-builds.md' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md imports isolated-builds.md"
else
  die "CLAUDE.md does not import @.claude/rules/isolated-builds.md"
fi

# 3. CLAUDE.md rules-count line is present and at least 14 (>= the count as
# of this rule's own PR, #784). Checked as a lower bound rather than an exact
# match so a later rule addition (e.g. #788's agent-role-selection.md, which
# bumps this to 15) doesn't spuriously fail this test — same fix applied
# retroactively here that test_reporting_style.sh already used for #783.
RULES_COUNT=$(grep -oE '[0-9]+ modular rule files' "$CLAUDE_MD" 2>/dev/null | grep -oE '^[0-9]+' | head -n 1)
if [ -n "$RULES_COUNT" ] && [ "$RULES_COUNT" -ge 14 ]; then
  pass "CLAUDE.md rules count present and >= 14 (found: $RULES_COUNT)"
else
  die "CLAUDE.md rules-count line missing or below 14 (found: ${RULES_COUNT:-none})"
fi
if grep -qi 'isolated builds' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md rules list names 'isolated builds'"
else
  die "CLAUDE.md rules list does not name 'isolated builds'"
fi

if [ "$fail" -eq 0 ]; then
  echo "All isolated-builds structural tests passed."
  exit 0
else
  echo "Some isolated-builds tests FAILED." >&2
  exit 1
fi

#!/bin/bash
# Structural tests for the reporting-style rule (me2resh/apexyard#782).
#
# The rule itself is self-discipline (voice can't be linted from a hook), so
# there's no runtime behaviour to exercise. What we CAN assert mechanically is
# that the artifacts exist and are wired in, so the rule can't silently rot:
#
#   1. .claude/rules/reporting-style.md exists and carries the ApexYard footer.
#   2. CLAUDE.md imports it via @.claude/rules/reporting-style.md.
#   3. CLAUDE.md's rules-count line is updated (13) and names "reporting style".
#   4. The opt-in output style exists with valid name + description frontmatter.
#
# Test style matches the existing tests/*.sh — bash + grep, no framework.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE="$SRC_ROOT/.claude/rules/reporting-style.md"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"
STYLE="$SRC_ROOT/.claude/output-styles/human-report.md"

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
if grep -q '@.claude/rules/reporting-style.md' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md imports reporting-style.md"
else
  die "CLAUDE.md does not import @.claude/rules/reporting-style.md"
fi

# 3. CLAUDE.md rules-count line is present and at least 13 (>= the count as
# of this rule's own PR, #783). Checked as a lower bound rather than an exact
# match so a later rule addition (e.g. #784's isolated-builds.md, which bumps
# this to 14) doesn't spuriously fail this test — see AgDR-driven rule growth.
RULES_COUNT=$(grep -oE '[0-9]+ modular rule files' "$CLAUDE_MD" 2>/dev/null | grep -oE '^[0-9]+' | head -n 1)
if [ -n "$RULES_COUNT" ] && [ "$RULES_COUNT" -ge 13 ]; then
  pass "CLAUDE.md rules count present and >= 13 (found: $RULES_COUNT)"
else
  die "CLAUDE.md rules-count line missing or below 13 (found: ${RULES_COUNT:-none})"
fi
if grep -qi 'reporting style' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md rules list names 'reporting style'"
else
  die "CLAUDE.md rules list does not name 'reporting style'"
fi

# 4. Output style exists with frontmatter
if [ -f "$STYLE" ]; then
  pass "output style file exists"
else
  die "output style missing: $STYLE"
fi
if grep -qE '^name:[[:space:]]*.+' "$STYLE" 2>/dev/null \
   && grep -qE '^description:[[:space:]]*.+' "$STYLE" 2>/dev/null; then
  pass "output style has name + description frontmatter"
else
  die "output style missing name/description frontmatter"
fi

if [ "$fail" -eq 0 ]; then
  echo "All reporting-style structural tests passed."
  exit 0
else
  echo "Some reporting-style tests FAILED." >&2
  exit 1
fi

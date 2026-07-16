#!/bin/bash
# Structural tests for the glossary-lookup rule (me2resh/apexyard#915).
#
# FR-8's on-demand single-term lookup ("what's a merge?", any session, any
# active skill) is deliberately an ambient rule, not a hook or a skill (see
# the rule's own "Backstop" section, and technical design
# docs/technical-designs/onboarding-increment-2.md § D4) — a shell hook
# can't see a plain-language question inside assistant prose, so there's no
# runtime behaviour to exercise mechanically. Same self-discipline shape as
# reporting-style.md / isolated-builds.md / agent-role-selection.md. What we
# CAN assert mechanically is that the artifacts exist and are wired in, so
# the rule can't silently rot:
#
#   1. .claude/rules/glossary-lookup.md exists and carries the ApexYard
#      footer.
#   2. CLAUDE.md imports it via @.claude/rules/glossary-lookup.md.
#   3. CLAUDE.md's rules-count line reads >= 18 and names "glossary lookup".
#   4. The rule points at the shared glossary asset it reads from
#      (docs/onboarding/glossary.md), so it can't drift onto a stale path.
#
# Test style matches the existing tests/*.sh (e.g. test_agent_role_selection.sh)
# — bash + grep, no framework.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE="$SRC_ROOT/.claude/rules/glossary-lookup.md"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"
GLOSSARY="$SRC_ROOT/docs/onboarding/glossary.md"

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
if grep -q '@.claude/rules/glossary-lookup.md' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md imports glossary-lookup.md"
else
  die "CLAUDE.md does not import @.claude/rules/glossary-lookup.md"
fi

# 3. CLAUDE.md rules-count line is present and at least 18 (>= the count as
# of this rule's own PR, #915). Checked as a lower bound, not an exact match,
# so a later rule addition doesn't spuriously fail this test — same pattern
# test_reporting_style.sh / test_agent_role_selection.sh established.
RULES_COUNT=$(grep -oE '[0-9]+ modular rule files' "$CLAUDE_MD" 2>/dev/null | grep -oE '^[0-9]+' | head -n 1)
if [ -n "$RULES_COUNT" ] && [ "$RULES_COUNT" -ge 18 ]; then
  pass "CLAUDE.md rules count present and >= 18 (found: $RULES_COUNT)"
else
  die "CLAUDE.md rules-count line missing or below 18 (found: ${RULES_COUNT:-none})"
fi
if grep -qi 'glossary lookup' "$CLAUDE_MD" 2>/dev/null; then
  pass "CLAUDE.md rules list names 'glossary lookup'"
else
  die "CLAUDE.md rules list does not name 'glossary lookup'"
fi

# 4. The rule references the shared glossary asset it reads from, and that
# asset exists (authored under #913) — catches the rule drifting onto a
# stale/renamed path.
if grep -q 'docs/onboarding/glossary.md' "$RULE" 2>/dev/null; then
  pass "rule file references docs/onboarding/glossary.md"
else
  die "rule file does not reference docs/onboarding/glossary.md"
fi
if [ -f "$GLOSSARY" ]; then
  pass "shared glossary asset exists"
else
  die "shared glossary asset missing: $GLOSSARY"
fi

if [ "$fail" -eq 0 ]; then
  echo "All glossary-lookup structural tests passed."
  exit 0
else
  echo "Some glossary-lookup tests FAILED." >&2
  exit 1
fi

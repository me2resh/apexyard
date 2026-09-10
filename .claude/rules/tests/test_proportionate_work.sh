#!/bin/bash
# Static contract tests for the "Proportionate work" extension of the
# right-size-ceremony rule shipped by me2resh/apexyard#1163. These checks pin
# the rule text, auto-load wiring, regression cases, rule-audit entry, and
# decision record. They do not claim to score model behavior; cross-harness
# evaluation belongs to #1165.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE_FILE="$SRC_ROOT/.claude/rules/right-size-ceremony.md"
CASES_FILE="$SRC_ROOT/.claude/rules/tests/fixtures/proportionate-work-cases.md"
AGDR_FILE="$SRC_ROOT/docs/agdr/AgDR-0125-proportionate-work-extends-right-size-tiers.md"

PASS=0
FAIL=0
FAILED=""

assert() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS [$label]"
    PASS=$((PASS+1))
  else
    echo "FAIL [$label]" >&2
    FAIL=$((FAIL+1))
    FAILED="${FAILED}${label} "
  fi
}

assert "rule:file-exists" test -f "$RULE_FILE"
assert "rule:section" grep -qE '^## Proportionate work' "$RULE_FILE"
assert "rule:four-phases" grep -qF '| **Planning** |' "$RULE_FILE"
assert "rule:implementation-phase" grep -qF '| **Implementation** |' "$RULE_FILE"
assert "rule:artifact-phase" grep -qF '| **Artifact creation** |' "$RULE_FILE"
assert "rule:smallest-change" grep -qF 'Start with the smallest change that satisfies the acceptance criteria' "$RULE_FILE"
assert "rule:reuse-first" grep -qF 'Reuse before you add' "$RULE_FILE"
assert "rule:demonstrated-need" grep -qF 'needs a demonstrated need' "$RULE_FILE"
assert "rule:advice-conversational" grep -qF 'Advice and quick assessments stay conversational' "$RULE_FILE"
assert "rule:rails-unchanged" grep -qF 'The rails do not move' "$RULE_FILE"
assert "rule:heavy-any-size" grep -qF 'is Heavy regardless of how small its diff is' "$RULE_FILE"
assert "rule:ambiguity-rounds-up" grep -qF 'Ambiguity rounds up' "$RULE_FILE"
assert "rule:agdr-not-skipped" grep -qF 'material at any diff size' "$RULE_FILE"
assert "rule:self-check-smallest" grep -qF 'smallest change that meets every acceptance criterion' "$RULE_FILE"
assert "rule:advisory-honesty" grep -qF 'It does not score model behavior' "$RULE_FILE"

assert "wiring:claude" grep -qF '@.claude/rules/right-size-ceremony.md' "$SRC_ROOT/CLAUDE.md"
assert "wiring:claude-extension" grep -qF 'smallest change that satisfies the acceptance criteria' "$SRC_ROOT/CLAUDE.md"
assert "wiring:agents" grep -qF '.claude/rules/right-size-ceremony.md' "$SRC_ROOT/AGENTS.md"
assert "wiring:system" grep -qF 'right-size-ceremony' "$SRC_ROOT/SYSTEM.md"
assert "wiring:cursor" grep -qF '.claude/rules/right-size-ceremony.md' "$SRC_ROOT/bin/sync-cursor-adapter.sh"
assert "wiring:rule-audit" grep -qF '.claude/rules/right-size-ceremony.md' "$SRC_ROOT/docs/rule-audit.md"

assert "cases:file-exists" test -f "$CASES_FILE"
assert "cases:seven-cases" bash -c "[ \"\$(grep -cE '^## PW-[0-9]{2} ' '$CASES_FILE')\" -eq 7 ]"
assert "cases:smallest" grep -qF 'Smallest sufficient change' "$CASES_FILE"
assert "cases:reuse" grep -qF 'Reuse before adding' "$CASES_FILE"
assert "cases:abstraction" grep -qF 'Undemonstrated abstraction' "$CASES_FILE"
assert "cases:advice" grep -qF 'Advice stays conversational' "$CASES_FILE"
assert "cases:lean-planning" grep -qF 'Lean planning' "$CASES_FILE"
assert "cases:heavy-unchanged" grep -qF 'Heavy safeguards are unchanged' "$CASES_FILE"
assert "cases:ambiguity" grep -qF 'Ambiguity rounds up' "$CASES_FILE"

assert "agdr:file-exists" test -f "$AGDR_FILE"
assert "agdr:no-yaml-frontmatter" bash -c "head -n1 '$AGDR_FILE' | grep -qE '^# '"
assert "agdr:options" grep -qE '^## Options Considered$' "$AGDR_FILE"
assert "agdr:decision" grep -qE '^## Decision$' "$AGDR_FILE"
assert "agdr:ticket" grep -qF 'me2resh/apexyard#1163' "$AGDR_FILE"

echo ""
echo "----------------------------------------"
echo "Proportionate-work rule smoke tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED"
  exit 1
fi
exit 0

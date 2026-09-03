#!/bin/bash
# Static contract tests for the universal evidence-grounding rule shipped by
# me2resh/apexyard#1162. These checks pin the source-of-truth rule, auto-load
# wiring, regression cases, rule-audit entry, and decision record. They do not
# claim to score model behavior; cross-harness evaluation belongs to #1165.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE_FILE="$SRC_ROOT/.claude/rules/evidence-grounding.md"
CASES_FILE="$SRC_ROOT/.claude/rules/tests/fixtures/evidence-grounding-cases.md"
AGDR_FILE="$SRC_ROOT/docs/agdr/AgDR-0124-universal-evidence-grounding-contract.md"

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
assert "rule:five-states" grep -qF 'Observed' "$RULE_FILE"
assert "rule:user-provided" grep -qF 'User-provided' "$RULE_FILE"
assert "rule:inferred" grep -qF 'Inferred' "$RULE_FILE"
assert "rule:proposed" grep -qF 'Proposed' "$RULE_FILE"
assert "rule:unknown" grep -qF 'Unknown' "$RULE_FILE"
assert "rule:context-boundary" grep -qF 'Scope each observation to the context that produced it' "$RULE_FILE"
assert "rule:mutable-state" grep -qF 'Re-check mutable state immediately before relying on it' "$RULE_FILE"
assert "rule:preserve-uncertainty" grep -qF 'Preserve uncertainty' "$RULE_FILE"
assert "rule:no-false-success" grep -qF 'without a success result' "$RULE_FILE"
assert "rule:advisory-honesty" grep -qF 'A shell hook cannot determine whether prose follows from evidence' "$RULE_FILE"

assert "wiring:claude" grep -qF '@.claude/rules/evidence-grounding.md' "$SRC_ROOT/CLAUDE.md"
assert "wiring:agents" grep -qF '.claude/rules/evidence-grounding.md' "$SRC_ROOT/AGENTS.md"
assert "wiring:system" grep -qF 'evidence-grounding' "$SRC_ROOT/SYSTEM.md"
assert "wiring:cursor" grep -qF '.claude/rules/evidence-grounding.md' "$SRC_ROOT/bin/sync-cursor-adapter.sh"
assert "wiring:rule-audit" grep -qF '.claude/rules/evidence-grounding.md' "$SRC_ROOT/docs/rule-audit.md"

assert "cases:file-exists" test -f "$CASES_FILE"
assert "cases:six-cases" bash -c "[ \"\$(grep -cE '^## EG-[0-9]{2} ' '$CASES_FILE')\" -eq 6 ]"
assert "cases:execution-context" grep -qF 'Execution-context boundary' "$CASES_FILE"
assert "cases:mutable-state" grep -qF 'Mutable CI state' "$CASES_FILE"
assert "cases:invented-id" grep -qF 'Invented tracker identifier' "$CASES_FILE"
assert "cases:inference" grep -qF 'Inference presented as observation' "$CASES_FILE"
assert "cases:modality" grep -qF 'Lost modality' "$CASES_FILE"
assert "cases:false-success" grep -qF 'Tool failure reported as success' "$CASES_FILE"

assert "agdr:file-exists" test -f "$AGDR_FILE"
assert "agdr:no-yaml-frontmatter" bash -c "head -n1 '$AGDR_FILE' | grep -qE '^# '"
assert "agdr:options" grep -qE '^## Options Considered$' "$AGDR_FILE"
assert "agdr:decision" grep -qE '^## Decision$' "$AGDR_FILE"
assert "agdr:ticket" grep -qF 'me2resh/apexyard#1162' "$AGDR_FILE"

echo ""
echo "----------------------------------------"
echo "Evidence-grounding rule smoke tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED"
  exit 1
fi
exit 0

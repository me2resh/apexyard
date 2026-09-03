#!/bin/bash
# Static contract tests for the writing-standard rule shipped by
# me2resh/apexyard#1164. These checks pin the rule text, auto-load wiring,
# template guidance comments, regression cases, rule-audit entry, and decision
# record. They do not claim to score model behavior; cross-harness evaluation
# belongs to #1165.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE_FILE="$SRC_ROOT/.claude/rules/writing-standard.md"
CASES_FILE="$SRC_ROOT/.claude/rules/tests/fixtures/human-friendly-cases.md"
AGDR_FILE="$SRC_ROOT/docs/agdr/AgDR-0126-writing-standard-two-modes.md"

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
assert "rule:two-modes" grep -qE '^## The two modes$' "$RULE_FILE"
assert "rule:opening" grep -qF 'Open with what the reader needs' "$RULE_FILE"
assert "rule:outcome" grep -qF '**Outcome**' "$RULE_FILE"
assert "rule:next-action" grep -qF '**Next action**' "$RULE_FILE"
assert "rule:required-core" grep -qF 'Small required core, conditional sections' "$RULE_FILE"
assert "rule:delete-empty" grep -qF 'Delete a conditional section that has nothing to say' "$RULE_FILE"
assert "rule:no-placeholder" grep -qF 'No placeholder survives' "$RULE_FILE"
assert "rule:strict-mode" grep -qF 'Strict mode for machine-consumed text' "$RULE_FILE"
assert "rule:one-instruction" grep -qF 'One instruction per sentence' "$RULE_FILE"
assert "rule:modality" grep -qF 'Exact modality' "$RULE_FILE"
assert "rule:flavored-mode" grep -qF 'Flavored mode for durable artifacts' "$RULE_FILE"
assert "rule:keep-uncertainty" grep -qF 'hedges that carry evidence state' "$RULE_FILE"
assert "rule:no-certification-claim" grep -qF 'does not claim certified STE compliance' "$RULE_FILE"
assert "rule:kill-criterion" grep -qF 'Move it to Flavored' "$RULE_FILE"
assert "rule:advisory-honesty" grep -qF 'It does not score model behavior' "$RULE_FILE"

assert "wiring:claude" grep -qF '@.claude/rules/writing-standard.md' "$SRC_ROOT/CLAUDE.md"
assert "wiring:agents" grep -qF '.claude/rules/writing-standard.md' "$SRC_ROOT/AGENTS.md"
assert "wiring:system" grep -qF 'writing-standard' "$SRC_ROOT/SYSTEM.md"
assert "wiring:cursor" grep -qF '.claude/rules/writing-standard.md' "$SRC_ROOT/bin/sync-cursor-adapter.sh"
assert "wiring:cursor-reporting" grep -qF '.claude/rules/reporting-style.md' "$SRC_ROOT/bin/sync-cursor-adapter.sh"
assert "wiring:rule-audit" grep -qF '.claude/rules/writing-standard.md' "$SRC_ROOT/docs/rule-audit.md"

for t in prd.md technical-design.md tickets/feature.md tickets/bug.md tickets/task.md; do
  assert "template:$t:required" grep -qF 'Required:' "$SRC_ROOT/templates/$t"
  assert "template:$t:conditional" grep -qF 'Conditional:' "$SRC_ROOT/templates/$t"
  assert "template:$t:rule-link" grep -qF 'writing-standard.md' "$SRC_ROOT/templates/$t"
done
assert "template:prd:summary" grep -qE '^## Summary$' "$SRC_ROOT/templates/prd.md"
assert "template:readme" grep -qF 'Required core and conditional sections' "$SRC_ROOT/templates/README.md"

assert "cases:file-exists" test -f "$CASES_FILE"
assert "cases:seven-cases" bash -c "[ \"\$(grep -cE '^## HF-[0-9]{2} ' '$CASES_FILE')\" -eq 7 ]"
assert "cases:opening" grep -qF 'Opening states the outcome and next action' "$CASES_FILE"
assert "cases:empty-section" grep -qF 'Empty conditional section is deleted' "$CASES_FILE"
assert "cases:placeholder" grep -qF 'No placeholder survives' "$CASES_FILE"
assert "cases:strict-block" grep -qF 'Strict mode block message' "$CASES_FILE"
assert "cases:strict-brief" grep -qF 'Strict mode spawn brief' "$CASES_FILE"
assert "cases:flavored" grep -qF 'Flavored mode keeps uncertainty and precision' "$CASES_FILE"
assert "cases:conversation" grep -qF 'Conversation is not forced into Strict mode' "$CASES_FILE"

assert "agdr:file-exists" test -f "$AGDR_FILE"
assert "agdr:no-yaml-frontmatter" bash -c "head -n1 '$AGDR_FILE' | grep -qE '^# '"
assert "agdr:options" grep -qE '^## Options Considered$' "$AGDR_FILE"
assert "agdr:decision" grep -qE '^## Decision$' "$AGDR_FILE"
assert "agdr:ticket" grep -qF 'me2resh/apexyard#1164' "$AGDR_FILE"

echo ""
echo "----------------------------------------"
echo "Writing-standard rule smoke tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED"
  exit 1
fi
exit 0

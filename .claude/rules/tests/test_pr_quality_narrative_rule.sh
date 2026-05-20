#!/bin/bash
# Smoke tests for the "PR summary bullets — narrative quality" rule shipped
# by me2resh/apexyard#312. The rule itself is prose, not a hook, so this test
# pins the documentation contracts across the four files that mention it:
#
#   - .claude/rules/pr-quality.md       — the rule + bad/good example pair
#   - .claude/agents/code-reviewer.md   — Rex's advisory check + heuristic
#   - workflows/code-review.md          — the cross-link from the workflow doc
#   - docs/agdr/AgDR-0029-*.md          — the AgDR with the four canonical sections
#
# Style matches the hook tests (.claude/hooks/tests/*.sh) — plain bash + grep,
# no external test framework, one PASS/FAIL line per assertion.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

RULE_FILE="$SRC_ROOT/.claude/rules/pr-quality.md"
AGENT_FILE="$SRC_ROOT/.claude/agents/code-reviewer.md"
WORKFLOW_FILE="$SRC_ROOT/workflows/code-review.md"
AGDR_FILE="$SRC_ROOT/docs/agdr/AgDR-0029-pr-summary-narrative-quality.md"

PASS=0
FAIL=0
FAILED=""

# assert <label> <test-command>
# Runs the test-command; PASS if exit 0, FAIL otherwise.
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

# --- pr-quality.md contracts --------------------------------------------------

assert "rule:file-exists" test -f "$RULE_FILE"

assert "rule:section-heading" \
  grep -qE '^## Summary bullets — narrative quality \(MANDATORY\)$' "$RULE_FILE"

# The bad-example block contains the label-only bullet shape from the ticket.
# `--` separates grep flags from the pattern (the pattern starts with `-`).
assert "rule:bad-example-state-fix" \
  grep -qF -- '- State fix' "$RULE_FILE"

assert "rule:bad-example-opa-rego" \
  grep -qF -- '- OPA/Rego compliance policies' "$RULE_FILE"

# The good-example block contains the narrative bullet shape.
assert "rule:good-example-fixed-state" \
  grep -qF 'Fixed broken repository state' "$RULE_FILE"

assert "rule:good-example-parallel-ci" \
  grep -qF 'Parallel CI quality gates' "$RULE_FILE"

# The rule explicitly mentions the two-question shape "what changed / why it matters".
assert "rule:two-questions" \
  grep -qE 'what changed.*why it matters' "$RULE_FILE"

# The legitimate-exceptions list is present so authors know when short is fine.
assert "rule:exceptions-section" \
  grep -qE '^### Legitimate exceptions' "$RULE_FILE"

# --- code-reviewer.md (Rex) contracts ----------------------------------------

assert "rex:file-exists" test -f "$AGENT_FILE"

# Rex's advisory sub-section is present.
assert "rex:advisory-subheading" \
  grep -qE 'Label-only summary bullets — advisory check' "$AGENT_FILE"

# The heuristic threshold is documented (≤ 6 words AND no verb).
assert "rex:heuristic-six-words" \
  grep -qE '≤ ?6 words' "$AGENT_FILE"

assert "rex:heuristic-no-verb" \
  grep -qiE 'no verb' "$AGENT_FILE"

# Rex's check is non-blocking — the file must state this explicitly so future
# maintainers don't accidentally promote it.
assert "rex:non-blocking-statement" \
  grep -qiE 'advisory|non-blocking|do NOT downgrade' "$AGENT_FILE"

# Skip condition for dependency bumps is named.
assert "rex:skip-dependency-bump" \
  grep -qiE 'dependency bump' "$AGENT_FILE"

# --- workflows/code-review.md cross-link contract ----------------------------

assert "workflow:file-exists" test -f "$WORKFLOW_FILE"

# The workflow doc references the new rule by section name AND by file path.
assert "workflow:cross-link-rule-path" \
  grep -qF '.claude/rules/pr-quality.md' "$WORKFLOW_FILE"

assert "workflow:cross-link-section" \
  grep -qiE 'narrative.*not.*label-only|label-only.*narrative' "$WORKFLOW_FILE"

# --- AgDR contracts ----------------------------------------------------------

assert "agdr:file-exists" test -f "$AGDR_FILE"

# Body-H1-only shape — first non-blank line must be an H1, no YAML frontmatter.
assert "agdr:no-yaml-frontmatter" \
  bash -c "head -n1 \"$AGDR_FILE\" | grep -qE '^# AgDR-0029'"

# The four canonical sections from templates/agdr.md.
assert "agdr:section-context" \
  grep -qE '^## Context$' "$AGDR_FILE"

assert "agdr:section-options" \
  grep -qE '^## Options Considered$' "$AGDR_FILE"

assert "agdr:section-decision" \
  grep -qE '^## Decision$' "$AGDR_FILE"

assert "agdr:section-consequences" \
  grep -qE '^## Consequences$' "$AGDR_FILE"

# The AgDR references the originating ticket.
assert "agdr:references-ticket" \
  grep -qF 'me2resh/apexyard#312' "$AGDR_FILE"

# --- summary ------------------------------------------------------------------

echo ""
echo "----------------------------------------"
echo "PR-quality narrative rule smoke tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED"
  exit 1
fi
exit 0

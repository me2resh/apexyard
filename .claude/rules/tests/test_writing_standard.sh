#!/bin/bash
# Static contract tests for the controlled technical writing profile in issue #1164.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RULE_FILE="$SRC_ROOT/.claude/rules/writing-standard.md"
CASES_FILE="$SRC_ROOT/.claude/rules/tests/fixtures/human-friendly-cases.md"
AGDR_FILE="$SRC_ROOT/docs/agdr/AgDR-0134-controlled-technical-writing-profile.md"

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
    FAILED="$FAILED$label "
  fi
}

assert "rule:file-exists" test -f "$RULE_FILE"
assert "rule:title" grep -qF 'Controlled Technical Writing Profile' "$RULE_FILE"
assert "rule:scope" grep -qF 'every project that' "$RULE_FILE"
assert "rule:short-sentences" grep -qF '20 words for an instruction' "$RULE_FILE"
assert "rule:active-voice" grep -qF 'Use active voice' "$RULE_FILE"
assert "rule:one-term" grep -qF 'Use one term for one item or action' "$RULE_FILE"
assert "rule:one-instruction" grep -qF 'Give one instruction in each sentence' "$RULE_FILE"
assert "rule:no-semicolon" grep -qF 'Do not use a semicolon' "$RULE_FILE"
assert "rule:preserve-evidence" grep -qF 'must not change the evidence' "$RULE_FILE"
assert "rule:no-retroactive-rewrite" grep -qF 'does not rewrite existing artifacts' "$RULE_FILE"
assert "rule:review-rejection" grep -qF 'must request changes' "$RULE_FILE"
assert "rule:no-certification-claim" grep -qF 'does not implement or claim' "$RULE_FILE"

assert "wiring:claude" grep -qF '.claude/rules/writing-standard.md' "$SRC_ROOT/CLAUDE.md"
assert "wiring:agents" grep -qF '.claude/rules/writing-standard.md' "$SRC_ROOT/AGENTS.md"
assert "wiring:system" grep -qF 'controlled technical writing profile' "$SRC_ROOT/SYSTEM.md"
assert "wiring:cursor" grep -qF 'controlled technical writing profile' "$SRC_ROOT/bin/sync-cursor-adapter.sh"
assert "wiring:rule-audit" grep -qF 'controlled technical writing profile' "$SRC_ROOT/docs/rule-audit.md"
does_not_mention_third_party_standard() {
  ! grep -qF 'third-party controlled-language standard' "$1"
}

assert "wiring:neutral-agents" does_not_mention_third_party_standard "$SRC_ROOT/AGENTS.md"
assert "wiring:neutral-claude" does_not_mention_third_party_standard "$SRC_ROOT/CLAUDE.md"

for t in prd.md technical-design.md tickets/feature.md tickets/bug.md tickets/task.md; do
  assert "template:$t:required" grep -qF 'Required:' "$SRC_ROOT/templates/$t"
  assert "template:$t:conditional" grep -qF 'Conditional:' "$SRC_ROOT/templates/$t"
done
while IFS= read -r template; do
  assert "template:$template:profile" grep -qF 'controlled technical writing profile' "$SRC_ROOT/$template"
done < <(find "$SRC_ROOT/templates" -type f -name '*.md' ! -name 'README.md' ! -name 'custom-templates.README.example.md' | sed "s|$SRC_ROOT/||" | sort)
first_line_is_yaml_delimiter() {
  head -n 1 "$1" | grep -qx -- '---'
}

assert "template:agdr-frontmatter" first_line_is_yaml_delimiter "$SRC_ROOT/templates/agdr.md"
assert "template:pr-body" grep -qF 'controlled technical writing profile' "$SRC_ROOT/.github/PULL_REQUEST_TEMPLATE.md"
assert "template:readme" grep -qF 'controlled technical writing profile' "$SRC_ROOT/templates/README.md"

while IFS= read -r skill; do
  assert "consumer:$skill:profile" grep -qF 'controlled technical writing profile' "$SRC_ROOT/.claude/skills/$skill/SKILL.md"
done < <(find "$SRC_ROOT/.claude/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -exec sh -c 'basename "$(dirname "$1")"' _ {} \; | sort)
assert "consumer:code-reviewer:profile" grep -qF 'controlled technical writing profile' "$SRC_ROOT/.claude/agents/code-reviewer.md"
assert "reviewer:code-review" grep -qF 'you must request changes' "$SRC_ROOT/.claude/skills/code-review/SKILL.md"
assert "reviewer:design-review" grep -qF 'you must request changes' "$SRC_ROOT/.claude/skills/design-review/SKILL.md"
assert "reviewer:rex" grep -qF 'Request changes when the artifact fails the profile' "$SRC_ROOT/.claude/agents/code-reviewer.md"
assert "pr-quality:profile" grep -qF 'controlled technical writing profile' "$SRC_ROOT/.claude/rules/pr-quality.md"
assert "consumer:tech-lead:profile" grep -qF 'controlled technical writing profile' "$SRC_ROOT/roles/engineering/tech-lead.md"

assert "cases:file-exists" test -f "$CASES_FILE"
assert "cases:ten-cases" awk '/^## HF-[0-9][0-9] /{count++} END{exit count != 10}' "$CASES_FILE"
assert "cases:pr-review" grep -qF 'PR and review use the profile' "$CASES_FILE"
assert "cases:rejection" grep -qF 'Reviewer rejects a profile fault' "$CASES_FILE"

assert "agdr:file-exists" test -f "$AGDR_FILE"
first_line_is_h1() { head -n 1 "$1" | grep -qE "^# "; }
assert "agdr:no-yaml-frontmatter" first_line_is_h1 "$AGDR_FILE"
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

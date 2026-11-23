#!/bin/bash
# Static contract tests for the one-page vision and the /tech-vision evidence draft (me2resh/apexyard#2152).
# Set TECH_VISION_ROOT to test another checkout tree.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="${TECH_VISION_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)}"
TEMPLATE="$SRC_ROOT/templates/architecture/vision.md"
APPENDIX="$SRC_ROOT/templates/architecture/vision-appendix.md"
SKILL="$SRC_ROOT/.claude/skills/tech-vision/SKILL.md"
OLD_AGDR="$SRC_ROOT/docs/agdr/AgDR-0028-tech-vision-skill-design.md"
NEW_AGDR="$(ls "$SRC_ROOT"/docs/agdr/AgDR-*-vision-evidence-drafts.md 2>/dev/null | head -n 1)"

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

has() { grep -qE -- "$1" "$2"; }
lacks() { ! grep -qE -- "$1" "$2"; }

# Template: one-page sections
assert "template exists" test -f "$TEMPLATE"
assert "template has Drivers section" has '^## Drivers$' "$TEMPLATE"
assert "template has NFR section" has '^## Non-functional requirements$' "$TEMPLATE"
assert "template has Principles section" has '^## Principles$' "$TEMPLATE"
assert "template has Reuse and vendors section" has '^## Reuse and vendors$' "$TEMPLATE"
assert "template has what we won't build section" has "^## What we won't build$" "$TEMPLATE"
assert "NFR table has target, today, how measured, source columns" has '^\| Requirement \| Target \| Today \| How measured \| Source' "$TEMPLATE"
assert "reuse list asks what already in place could replace it" has 'What already in place could replace it' "$TEMPLATE"
assert "won't build items carry a reconsider when trigger" has 'Reconsider when:' "$TEMPLATE"
assert "drivers are ranked" has '[Rr]ank' "$TEMPLATE"
assert "template is one page (default has no 26-section list)" test "$(grep -c '^## ' "$TEMPLATE")" -le 7
assert "template drops the old 7-section Migration path" lacks '^## Migration path$' "$TEMPLATE"

# Template: rules
assert "template rule: Not relevant with reason" has 'Not relevant: <reason>' "$TEMPLATE"
assert "template rule: number has a source and a date or estimate" has 'source and a date, or it is labelled `\(estimate\)`' "$TEMPLATE"
assert "template rule: unknown value is not set with an owner" has 'not set \(owner: <name>\)' "$TEMPLATE"
assert "template points to the optional appendix" has 'vision-appendix\.md' "$TEMPLATE"

# Appendix
assert "appendix exists" test -f "$APPENDIX"
assert "appendix is optional" has '^> Optional\.' "$APPENDIX"
for h in "Business context" "Capabilities" "Load and growth" "Data and processors" "Legal and regulatory" "Security posture" "Organisation and operations" "Limits and assumptions" "Alternatives" "Decisions" "Cost model" "Trade-offs" "Risks" "Target state" "Migration path" "Fitness functions and review triggers"; do
  assert "appendix has section: $h" has "^## $h$" "$APPENDIX"
done
assert "appendix has no trace IDs" lacks '\b[A-Z]{1,6}-[0-9]+\b' "$APPENDIX"
assert "appendix repeats the not-set rule" has 'not set \(owner: <name>\)' "$APPENDIX"
assert "appendix puts Target state before Migration path" bash -c 'awk "/^## Target state$/{t=NR} /^## Migration path$/{m=NR} END{exit !(t && m && t < m)}" "$1"' _ "$APPENDIX"
assert "one-page vision points to the appendix Target state" has 'Target state section of the appendix' "$TEMPLATE"
assert "evidence draft never copies a credential" has 'Never copy a credential, token, key or connection string' "$SKILL"

# Skill
assert "skill exists" test -f "$SKILL"
assert "skill documents the table answer shape with a source on each number" has 'Table with a source on each number' "$SKILL"
assert "skill documents the not relevant answer shape" has 'Not relevant, because' "$SKILL"
assert "skill writes Not relevant: <reason>" has 'Not relevant: <reason>' "$SKILL"
assert "skill documents the not-set rule with an owner" has 'not set \(owner: <name>\)' "$SKILL"
assert "skill has an evidence-draft step" has '^### 3\. Draft evidence \(factual sections only\)' "$SKILL"
assert "evidence draft lists load, cost, data flows, processors, reuse and vendors" has 'the reuse and vendor list \(from dependency manifests' "$SKILL"
assert "evidence draft shows the source of each value" has 'Show the value with its source' "$SKILL"
assert "evidence draft: operator confirms or corrects each value" has 'confirm or correct each value' "$SKILL"
assert "evidence draft never covers drivers, principles, risk appetite, won't build" has "Never draft these sections: drivers, principles, risk appetite, what we won't build" "$SKILL"
assert "skill still reads sections from the template headings" has '\^##. headings' "$SKILL"
assert "skill offers the Heavy appendix as opt-in" has 'Add the Heavy appendix' "$SKILL"
assert "skill no longer forbids all drafting" lacks 'Never complete section bodies on the operator' "$SKILL"
assert "skill stays within the 16000 byte cap" test "$(wc -c < "$SKILL")" -le 16000

# AgDRs
assert "new AgDR exists" test -n "$NEW_AGDR"
assert "new AgDR number is above 0321" test "$(basename "${NEW_AGDR:-AgDR-0000-x}" | sed -E 's/^AgDR-0*([0-9]+)-.*/\1/')" -gt 321
assert "new AgDR names AgDR-0028" has 'AgDR-0028' "${NEW_AGDR:-/dev/null}"
assert "new AgDR records the factual-sections-only limit" has '[Dd]raft factual sections only' "${NEW_AGDR:-/dev/null}"
assert "AgDR-0028 is marked superseded in part" has '^\*\*Superseded in part by AgDR-[0-9]+' "$OLD_AGDR"

echo ""
echo "tech-vision v2: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED" >&2
  exit 1
fi
exit 0

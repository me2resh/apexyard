#!/bin/bash
# Smoke test for the /handover skill's harnessability-assessment step
# introduced in me2resh/apexyard#298.
#
# Pins the documentation contracts that downstream re-implementations
# (and adopters relying on the public surface) need to be able to grep
# for. The actual scoring logic is descriptive bash pseudocode in
# SKILL.md — this test does NOT execute the scoring; it asserts the
# documentation invariants hold.
#
# Validates:
#   1. SKILL.md mentions the harnessability assessment step
#   2. SKILL.md names all 5 dimensions
#   3. SKILL.md documents each dimension's verdict buckets
#   4. SKILL.md has a verdict-thresholds truth table for high/moderate/low
#   5. SKILL.md contains the exact `low` warning wording (verbatim)
#   6. SKILL.md adds a "Harnessability assessment" section to the
#      assessment-file template (so the persisted artefact shape is fixed)
#   7. AgDR-0042 exists, starts with the canonical H1 header,
#      has no YAML frontmatter, and contains the "In the context of..."
#      one-liner
#   8. AgDR-0042 names the 5 dimensions in its Decision section
#   9. AgDR-0042 references the ticket (#298)
#  10. CLAUDE.md /handover skill row mentions harnessability
#  11. docs/multi-project.md /handover skill row mentions harnessability
#  12. Skill count in CLAUDE.md is unchanged (this is an extension to an
#      existing skill, not a new one)
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKILL_MD="$SRC_ROOT/.claude/skills/handover/SKILL.md"
AGDR="$SRC_ROOT/docs/agdr/AgDR-0042-harnessability-scoring-dimensions.md"
CLAUDE_MD="$SRC_ROOT/CLAUDE.md"
MULTI_DOC="$SRC_ROOT/docs/multi-project.md"

for f in "$SKILL_MD" "$AGDR" "$CLAUDE_MD" "$MULTI_DOC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

# ---------------------------------------------------------------------------
# Case 1: SKILL.md mentions the harnessability assessment step.
# ---------------------------------------------------------------------------
if grep -qE '^### 4\.5\. Harnessability assessment' "$SKILL_MD"; then
  mark_pass "1. SKILL.md has the '### 4.5. Harnessability assessment' step"
else
  mark_fail "1. harnessability step heading" "no '### 4.5. Harnessability assessment' header in SKILL.md"
fi

# ---------------------------------------------------------------------------
# Case 2: SKILL.md names all 5 dimensions in the step.
# ---------------------------------------------------------------------------
missing_dims=""
for dim in "Type safety" "Module boundaries" "Framework opinionation" "Test coverage signal" "Lint baseline"; do
  if ! grep -qF "$dim" "$SKILL_MD"; then
    missing_dims="$missing_dims | $dim"
  fi
done
if [ -z "$missing_dims" ]; then
  mark_pass "2. all 5 dimensions named in SKILL.md (Type safety / Module boundaries / Framework opinionation / Test coverage signal / Lint baseline)"
else
  mark_fail "2. dimensions named" "missing:$missing_dims"
fi

# ---------------------------------------------------------------------------
# Case 3: per-dimension verdict buckets present.
# ---------------------------------------------------------------------------
# Type safety: strong/partial/none
# Module boundaries: strong/partial/flat
# Framework opinionation: strong/moderate/weak
# Test coverage signal / Lint baseline: present/absent
buckets_ok=1
grep -q 'strong.*partial.*none\|strong / partial / none' "$SKILL_MD"      || buckets_ok=0
grep -q 'strong.*partial.*flat\|strong / partial / flat' "$SKILL_MD"      || buckets_ok=0
grep -q 'strong.*moderate.*weak\|strong / moderate / weak' "$SKILL_MD"    || buckets_ok=0
grep -q 'present.*absent\|present / absent' "$SKILL_MD"                   || buckets_ok=0
if [ "$buckets_ok" = "1" ]; then
  mark_pass "3. per-dimension verdict buckets documented (strong/partial/none, strong/partial/flat, strong/moderate/weak, present/absent)"
else
  mark_fail "3. verdict buckets" "one or more bucket triples missing"
fi

# ---------------------------------------------------------------------------
# Case 4: overall verdict thresholds documented in SKILL.md.
# Requires the truth-table mention of "high", "moderate", "low" buckets
# plus the strong-or-present count concept (5/5, 3 or 4/5, ≤2/5).
# ---------------------------------------------------------------------------
thresholds_ok=1
grep -qE '\b5 ?/ ?5\b|`high`' "$SKILL_MD"                     || thresholds_ok=0
grep -qE '\b3 or 4|3-4|`moderate`' "$SKILL_MD"                || thresholds_ok=0
grep -qE '≤ ?2|<= ?2|`low`' "$SKILL_MD"                       || thresholds_ok=0
# The (type-safety=none + framework=weak) override is load-bearing — pin it.
if ! grep -qE 'none.*weak|weak.*none' "$SKILL_MD"; then
  thresholds_ok=0
fi
if [ "$thresholds_ok" = "1" ]; then
  mark_pass "4. verdict thresholds documented (high=5/5, moderate=3-4/5, low=≤2/5 + (none + weak) override)"
else
  mark_fail "4. verdict thresholds" "one of high/moderate/low/override missing"
fi

# ---------------------------------------------------------------------------
# Case 5: the exact `low` warning wording is in SKILL.md (verbatim).
# Pin the most identity-load-bearing fragment.
# ---------------------------------------------------------------------------
WARN_NEEDLE='Rex'\''s architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)'
if grep -qF "$WARN_NEEDLE" "$SKILL_MD"; then
  mark_pass "5. exact 'low'-verdict warning text present in SKILL.md (verbatim)"
else
  mark_fail "5. low-verdict warning verbatim" "exact wording not found in SKILL.md"
fi

# ---------------------------------------------------------------------------
# Case 6: assessment-file template includes a Harnessability assessment
# section so the persisted artefact carries the score.
# ---------------------------------------------------------------------------
if grep -qE '^## Harnessability assessment' "$SKILL_MD"; then
  mark_pass "6. assessment-file template has a '## Harnessability assessment' section"
else
  mark_fail "6. assessment-file section" "'## Harnessability assessment' not found in the assessment template"
fi

# ---------------------------------------------------------------------------
# Case 7: AgDR-0042 exists, has the canonical body-H1, and no YAML
# frontmatter. The framework's live convention (drift from
# templates/agdr.md, see active feedback memory) is body-H1 only.
# ---------------------------------------------------------------------------
first_line=$(head -n 1 "$AGDR")
if [ "$first_line" = "# AgDR-0042 — Harnessability scoring dimensions and thresholds" ]; then
  mark_pass "7a. AgDR-0042 starts with the canonical body-H1 header"
else
  mark_fail "7a. canonical H1" "first line was: $first_line"
fi

# YAML frontmatter would be a leading '---' line.
if [ "$first_line" = "---" ]; then
  mark_fail "7b. no YAML frontmatter" "AgDR-0042 starts with --- (YAML frontmatter forbidden by live convention)"
else
  mark_pass "7b. AgDR-0042 has no YAML frontmatter"
fi

# "In the context of..." one-liner immediately under the H1.
if grep -qE '^> In the context of' "$AGDR"; then
  mark_pass "7c. AgDR-0042 contains the 'In the context of...' one-liner"
else
  mark_fail "7c. context one-liner" "no 'In the context of...' block-quote in AgDR-0042"
fi

# ---------------------------------------------------------------------------
# Case 8: AgDR-0042 names the 5 dimensions in its narrative.
# ---------------------------------------------------------------------------
agdr_dims_missing=""
for dim in "type safety" "module boundaries" "framework opinionation" "test coverage signal" "lint baseline"; do
  if ! grep -iqF "$dim" "$AGDR"; then
    agdr_dims_missing="$agdr_dims_missing | $dim"
  fi
done
if [ -z "$agdr_dims_missing" ]; then
  mark_pass "8. AgDR-0042 names all 5 dimensions"
else
  mark_fail "8. AgDR-0042 dimensions" "missing:$agdr_dims_missing"
fi

# ---------------------------------------------------------------------------
# Case 9: AgDR-0042 references the originating ticket (#298).
# ---------------------------------------------------------------------------
if grep -qE 'me2resh/apexyard#298|/issues/298|#298' "$AGDR"; then
  mark_pass "9. AgDR-0042 references ticket #298"
else
  mark_fail "9. ticket cross-reference" "no #298 reference found in AgDR-0042"
fi

# ---------------------------------------------------------------------------
# Case 10: CLAUDE.md /handover skill row mentions harnessability.
# ---------------------------------------------------------------------------
# Find the /handover skill-row line; grep for "harnessability" within it.
handover_row_claude=$(grep -E '^\| `/handover` \|' "$CLAUDE_MD" || true)
if echo "$handover_row_claude" | grep -iqF "harnessability"; then
  mark_pass "10. CLAUDE.md /handover skill row mentions harnessability"
else
  mark_fail "10. CLAUDE.md /handover row" "no 'harnessability' on the /handover row"
fi

# ---------------------------------------------------------------------------
# Case 11: docs/multi-project.md /handover skill row mentions harnessability.
# ---------------------------------------------------------------------------
handover_row_multi=$(grep -E '^\| `/handover` \|' "$MULTI_DOC" || true)
if echo "$handover_row_multi" | grep -iqF "harnessability"; then
  mark_pass "11. docs/multi-project.md /handover skill row mentions harnessability"
else
  mark_fail "11. multi-project.md /handover row" "no 'harnessability' on the /handover row"
fi

# ---------------------------------------------------------------------------
# Case 12: skill count unchanged in CLAUDE.md — this is an extension to
# an existing skill, not a new skill. The framework currently lists 51
# skills (per the table header line). Pin that — a future legitimate
# skill count bump will need to update this test.
# ---------------------------------------------------------------------------
if grep -qE '### Available skills \(51\)' "$CLAUDE_MD"; then
  mark_pass "12. CLAUDE.md still reports 51 skills (no spurious count bump)"
else
  mark_fail "12. skill count" "the '### Available skills (51)' header changed — this extension should not bump the count"
fi

# ---------------------------------------------------------------------------
echo ""
echo "$PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED" >&2
  exit 1
fi
exit 0

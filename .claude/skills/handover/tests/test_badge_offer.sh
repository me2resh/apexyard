#!/bin/bash
# Smoke test for the /handover skill's "Governed by ApexYard" badge offer
# introduced in me2resh/apexyard#796.
#
# Pins the documentation contracts that downstream re-implementations (and
# adopters relying on the public surface) need to be able to grep for. The
# actual insertion logic is descriptive bash/awk pseudocode in SKILL.md —
# this test does NOT execute it; it asserts the documentation invariants
# hold.
#
# Validates:
#   1. SKILL.md mentions step 8.6 (the badge offer step)
#   2. SKILL.md's step 5.6 catalogue has a row 9 for the badge
#   3. SKILL.md documents the badge as default-OFF
#   4. SKILL.md contains the exact "governed_by" shields.io badge markdown
#   5. SKILL.md contains the exact "built_with" shields.io badge markdown
#   6. Both badge snippets use the brand color 2F6DF6 and flat-square style
#   7. SKILL.md documents the idempotency check (skip if already present)
#   8. SKILL.md documents branch + PR delivery (never a direct commit) for
#      the badge step
#   9. SKILL.md's Rule 1 exception note names both AGENTS.md and the badge
#  10. SKILL.md has a Rule 23 documenting the badge's opt-in contract
#  11. SKILL.md's step 10 summary template has a badge status line
#  12. AgDR-0090 exists, starts with the canonical H1 header, has no YAML
#      frontmatter, and contains the "In the context of..." one-liner
#  13. AgDR-0090 references the ticket (#796)
#  14. docs/multi-project.md's /handover row mentions step 8.6 / the badge
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
SKILL_MD="$SRC_ROOT/.claude/skills/handover/SKILL.md"
AGDR="$SRC_ROOT/docs/agdr/AgDR-0090-handover-badge-offer.md"
MULTI_DOC="$SRC_ROOT/docs/multi-project.md"

for f in "$SKILL_MD" "$AGDR" "$MULTI_DOC"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: expected file missing: $f"
    exit 1
  fi
done

FAIL=0

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }

fail() {
  red "FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  green "PASS: $1"
}

# 1. Step 8.6 exists
if grep -q '^### 8.6\. Offer the "Governed by ApexYard" badge' "$SKILL_MD"; then
  pass "step 8.6 documented"
else
  fail "step 8.6 (badge offer) not found in SKILL.md"
fi

# 2. Catalogue row 9
if grep -qE '^\| 9 \| "Governed by ApexYard" README badge' "$SKILL_MD"; then
  pass "step 5.6 catalogue row 9 documented"
else
  fail "step 5.6 catalogue row 9 for the badge not found"
fi

# 3. Default-OFF
if grep -q 'row 9 of the step 5.6 checklist is \*\*default-OFF\*\*' "$SKILL_MD"; then
  pass "badge documented as default-OFF"
else
  fail "badge default-OFF wording not found"
fi

# 4. governed_by badge markdown (exact)
GOVERNED_BADGE='[![Governed by ApexYard](https://img.shields.io/badge/governed_by-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)'
if grep -qF "$GOVERNED_BADGE" "$SKILL_MD"; then
  pass "governed_by badge markdown present verbatim"
else
  fail "governed_by badge markdown not found verbatim in SKILL.md"
fi

# 5. built_with badge markdown (exact)
BUILT_WITH_BADGE='[![Built with ApexYard](https://img.shields.io/badge/built_with-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)'
if grep -qF "$BUILT_WITH_BADGE" "$SKILL_MD"; then
  pass "built_with badge markdown present verbatim"
else
  fail "built_with badge markdown not found verbatim in SKILL.md"
fi

# 6. Brand color + style called out explicitly
if grep -q '2F6DF6' "$SKILL_MD" && grep -q 'flat-square' "$SKILL_MD"; then
  pass "brand color (2F6DF6) and flat-square style referenced"
else
  fail "brand color / flat-square style not referenced in SKILL.md"
fi

# 7. Idempotency check documented
if grep -qi 'Idempotency check' "$SKILL_MD" && grep -qi 'already present' "$SKILL_MD"; then
  pass "idempotency check documented"
else
  fail "idempotency check (skip if already present) not documented"
fi

# 8. Branch + PR delivery, never a direct commit
if grep -q 'Branch + PR, never a direct commit to the default branch' "$SKILL_MD"; then
  pass "branch+PR delivery documented (shared wording with AGENTS.md step)"
else
  fail "branch + PR delivery wording not found for the badge step"
fi

# 9. Rule 1 exception names both AGENTS.md and the badge
if grep -q 'in-repo `AGENTS.md` generation and the "Governed by ApexYard" README badge' "$SKILL_MD"; then
  pass "Rule 1 exception note names both target-repo writes"
else
  fail "Rule 1 exception note doesn't name both AGENTS.md and the badge"
fi

# 10. Rule 23 exists
if grep -qE '^23\. \*\*The "Governed by ApexYard" badge' "$SKILL_MD"; then
  pass "Rule 23 (badge contract) documented"
else
  fail "Rule 23 for the badge not found"
fi

# 11. Step 10 summary line
if grep -q 'Governed-by-ApexYard badge:' "$SKILL_MD"; then
  pass "step 10 summary includes a badge status line"
else
  fail "step 10 summary is missing the badge status line"
fi

# 12. AgDR-0090 shape
if head -1 "$AGDR" | grep -qE '^# AgDR-0090 '; then
  pass "AgDR-0090 has the canonical H1 header"
else
  fail "AgDR-0090 missing/malformed H1 header"
fi
if head -5 "$AGDR" | grep -q '^---$'; then
  fail "AgDR-0090 appears to have YAML frontmatter (should be body-H1 only)"
else
  pass "AgDR-0090 has no YAML frontmatter"
fi
if grep -q 'In the context of' "$AGDR"; then
  pass "AgDR-0090 has the canonical one-liner"
else
  fail "AgDR-0090 missing the 'In the context of...' one-liner"
fi

# 13. AgDR-0090 references the ticket
if grep -q '#796' "$AGDR"; then
  pass "AgDR-0090 references ticket #796"
else
  fail "AgDR-0090 does not reference ticket #796"
fi

# 14. docs/multi-project.md mentions step 8.6 / the badge
if grep -q 'Step 8.6' "$MULTI_DOC" && grep -q 'Governed by ApexYard' "$MULTI_DOC"; then
  pass "docs/multi-project.md documents step 8.6 / the badge"
else
  fail "docs/multi-project.md does not document step 8.6 / the badge"
fi

if [ "$FAIL" -gt 0 ]; then
  red "$FAIL check(s) failed"
  exit 1
fi

green "All checks passed"
exit 0

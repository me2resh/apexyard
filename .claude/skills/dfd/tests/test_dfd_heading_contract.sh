#!/usr/bin/env bash
# test_dfd_heading_contract.sh
#
# me2resh/apexyard#1358 — /dfd's hand-authored template used a different
# heading set than /threat-model's Step 1b extractor expected, so a DFD
# written by hand from templates/architecture/dfd.md silently produced an
# empty "## Data classifications" snapshot section (0 bytes, no warning).
#
# This test pins the three-heading contract shared by:
#   - templates/architecture/dfd.md          (the hand-authored template)
#   - .claude/skills/dfd/generate-mermaid.sh (the generated-DFD path)
#   - .claude/skills/threat-model/SKILL.md   (Step 1b's awk extractor)
#   - .claude/skills/dfd/SKILL.md            (the heading-contract rule)
#
# so a future rename/drop of any of the three headings in any one file
# fails this test instead of silently zeroing out a snapshot section.
#
# Usage: bash .claude/skills/dfd/tests/test_dfd_heading_contract.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DFD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$(cd "$DFD_DIR/.." && pwd)"
ROOT="$(cd "$SKILLS_DIR/../.." && pwd)"

TEMPLATE="$ROOT/templates/architecture/dfd.md"
GENERATOR="$DFD_DIR/generate-mermaid.sh"
DFD_SKILL="$DFD_DIR/SKILL.md"
TM_SKILL="$SKILLS_DIR/threat-model/SKILL.md"

for f in "$TEMPLATE" "$GENERATOR" "$DFD_SKILL" "$TM_SKILL"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: expected file missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

assert_has() {
  local label="$1" file="$2" needle="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected to find: $needle)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

echo ""
echo "1) The three contract headings appear verbatim in all four files"

HEADINGS=("## Diagram" "## Trust boundaries" "## Data classifications")

for heading in "${HEADINGS[@]}"; do
  assert_has "template carries '$heading'"          "$TEMPLATE"  "$heading"
  assert_has "generate-mermaid.sh emits '$heading'"  "$GENERATOR" "$heading"
  assert_has "dfd/SKILL.md names '$heading'"         "$DFD_SKILL" "$heading"
  assert_has "threat-model/SKILL.md extracts '$heading'" "$TM_SKILL" "$heading"
done

echo ""
echo "2) threat-model/SKILL.md's Step 1b awk patterns anchor on the exact headings"

# The extractor in threat-model/SKILL.md is documented, not executable in
# isolation (it reads $dfd, set earlier in that skill's flow) — so pin the
# three awk anchor patterns directly, the same strings Step 1b greps for.
assert_has "Step 1b anchors on '/^## Diagram/'"             "$TM_SKILL" '/^## Diagram/'
assert_has "Step 1b anchors on '/^## Trust boundaries/'"    "$TM_SKILL" '/^## Trust boundaries/'
assert_has "Step 1b anchors on '/^## Data classifications/'" "$TM_SKILL" '/^## Data classifications/'

echo ""
echo "3) Negative case (the #1358 repro) — extraction against a template"
echo "   missing the heading returns empty; extraction against a template"
echo "   carrying it returns non-empty"

FIXTURES=$(mktemp -d -t dfd-heading-contract-XXXXXX)
trap 'rm -rf "$FIXTURES"' EXIT

# Reproduces the pre-fix templates/architecture/dfd.md shape: Diagram +
# Trust boundaries + Notes, no Data classifications section at all.
cat > "$FIXTURES/pre-fix.md" <<'MD'
## Diagram

```mermaid
flowchart LR
  A --> B
```

## Trust boundaries

| From | To |
|------|-----|
| A | B |

## Notes

Some notes.
MD

# The fixed shape: same as above, plus a Data classifications section.
cat > "$FIXTURES/post-fix.md" <<'MD'
## Diagram

```mermaid
flowchart LR
  A --> B
```

## Trust boundaries

| From | To |
|------|-----|
| A | B |

## Data classifications

| Label | Data element |
|-------|--------------|
| PII | email |

## Notes

Some notes.
MD

extract_classifications() {
  # Identical extraction logic to threat-model/SKILL.md Step 1b.
  awk '
    /^## Data classifications/ { capture = 1 }
    /^## / && !/^## Data classifications/ { if (capture && NR > 1) exit }
    capture                    { print }
  ' "$1"
}

pre_fix_out=$(extract_classifications "$FIXTURES/pre-fix.md")
if [ -z "$pre_fix_out" ]; then
  echo "  PASS: pre-fix fixture (no heading) extracts to empty — reproduces #1358"
  PASS=$((PASS + 1))
else
  echo "  FAIL: pre-fix fixture unexpectedly extracted content: $pre_fix_out"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  pre-fix fixture should extract empty"
fi

post_fix_out=$(extract_classifications "$FIXTURES/post-fix.md")
if [ -n "$post_fix_out" ] && printf '%s' "$post_fix_out" | grep -qF "PII"; then
  echo "  PASS: post-fix fixture (heading present) extracts the table"
  PASS=$((PASS + 1))
else
  echo "  FAIL: post-fix fixture did not extract the expected table"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  post-fix fixture should extract the table"
fi

# The real template shipped in this repo must behave like post-fix.md, not
# pre-fix.md — this is the actual regression guard for #1358.
template_out=$(extract_classifications "$TEMPLATE")
if [ -n "$template_out" ]; then
  echo "  PASS: templates/architecture/dfd.md extracts a non-empty Data classifications section"
  PASS=$((PASS + 1))
else
  echo "  FAIL: templates/architecture/dfd.md still extracts empty — #1358 regressed"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  shipped template should extract non-empty"
fi

echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$FAILED_CASES"
  exit 1
fi
echo ""
echo "OK: dfd/threat-model heading contract holds."
exit 0

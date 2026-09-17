#!/bin/bash
# Tests for review_validate_rex_body and review_write_rex_approved
# (me2resh/apexyard#1322, AgDR-0161).
#
# The helper refuses a marker write when the local body lacks required
# Output Format headings, or when the verdict is not APPROVED. The merge
# gate still reads only the SHA from a successful write.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$LIB"

PASS=0
FAIL=0
FAILED=""

mark_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
mark_fail() { echo "  ✗ $1: $2" >&2; FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; }

SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

write_complete_body() {
  local dest="$1"
  local verdict="${2:-APPROVED}"
  cat > "$dest" <<EOF
${verdict}. Merge after the CEO nod.

## Code Review: PR #1

**Commit**: \`${SHA}\`
**Scope**: \`Full\`

### Summary
Backfill missing review-body validation.

### Checklist Results
- Architecture & Design: N/A — no application code

### Issues Found
None

### Validation
bash test — pass

### Verdict
**${verdict}**

---
🤖 Reviewed by Rex (Code Reviewer Agent)
📌 Reviewed commit: \`${SHA}\`
EOF
}

# Complete APPROVED body allows the marker write. Marker is SHA plus newline.
BODY="$TMP/ok.md"
MARKER="$TMP/reviews/me2resh__apexyard__1-rex.approved"
write_complete_body "$BODY" "APPROVED"
if review_write_rex_approved "$BODY" "$SHA" "$MARKER" \
   && [ "$(tr -d '[:space:]' < "$MARKER")" = "$SHA" ] \
   && [ "$(wc -c < "$MARKER" | tr -d ' ')" = "41" ]; then
  mark_pass "complete APPROVED body writes SHA-only marker"
else
  mark_fail "complete APPROVED write" "rc or marker contents"
fi

# Empty body fails.
: > "$TMP/empty.md"
if review_validate_rex_body "$TMP/empty.md" 2>/dev/null; then
  mark_fail "empty body" "expected fail"
else
  mark_pass "empty body fails"
fi

# Missing ### Validation fails.
NO_VAL="$TMP/no-validation.md"
write_complete_body "$NO_VAL" "APPROVED"
# Drop the Validation heading line and its following paragraph start.
# Safer: rewrite without that heading.
awk '!/^### Validation$/' "$NO_VAL" > "$TMP/no-validation2.md"
if review_validate_rex_body "$TMP/no-validation2.md" 2>/dev/null; then
  mark_fail "omit Validation" "expected fail"
else
  mark_pass "body that omits ### Validation fails"
fi

# ## Checklist does not satisfy ### Checklist Results.
WRONG="$TMP/wrong-checklist.md"
write_complete_body "$WRONG" "APPROVED"
sed 's/^### Checklist Results$/## Checklist/' "$WRONG" > "$TMP/wrong-checklist2.md"
if review_validate_rex_body "$TMP/wrong-checklist2.md" 2>/dev/null; then
  mark_fail "## Checklist alias" "expected fail"
else
  mark_pass "## Checklist instead of ### Checklist Results fails"
fi

# CHANGES REQUESTED must not write a marker.
CR="$TMP/changes.md"
CR_MARKER="$TMP/reviews/changes.approved"
write_complete_body "$CR" "CHANGES REQUESTED"
rm -f "$CR_MARKER"
if review_write_rex_approved "$CR" "$SHA" "$CR_MARKER" 2>/dev/null; then
  mark_fail "CHANGES REQUESTED write" "expected refuse"
elif [ -f "$CR_MARKER" ]; then
  mark_fail "CHANGES REQUESTED write" "marker was created"
else
  mark_pass "CHANGES REQUESTED verdict does not write a marker"
fi

# Missing file fails.
if review_validate_rex_body "$TMP/missing.md" 2>/dev/null; then
  mark_fail "missing file" "expected fail"
else
  mark_pass "missing body file fails"
fi

# NOT APPROVED must not write. Substring "APPROVED" is not enough.
NOTA="$TMP/not-approved.md"
NOTA_MARKER="$TMP/reviews/not-approved.approved"
write_complete_body "$NOTA" "NOT APPROVED"
rm -f "$NOTA_MARKER"
if review_write_rex_approved "$NOTA" "$SHA" "$NOTA_MARKER" 2>/dev/null; then
  mark_fail "NOT APPROVED write" "expected refuse"
elif [ -f "$NOTA_MARKER" ]; then
  mark_fail "NOT APPROVED write" "marker was created"
else
  mark_pass "NOT APPROVED verdict does not write a marker"
fi

# Footer SHA must match the SHA being written.
MISMATCH="$TMP/mismatch.md"
MISMATCH_MARKER="$TMP/reviews/mismatch.approved"
write_complete_body "$MISMATCH" "APPROVED"
OTHER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
rm -f "$MISMATCH_MARKER"
if review_write_rex_approved "$MISMATCH" "$OTHER" "$MISMATCH_MARKER" 2>/dev/null; then
  mark_fail "footer SHA mismatch" "expected refuse"
elif [ -f "$MISMATCH_MARKER" ]; then
  mark_fail "footer SHA mismatch" "marker was created"
else
  mark_pass "footer SHA mismatch does not write a marker"
fi

# Required headings stay a subset of the Rex Output Format template.
REX_FILE="$SRC_ROOT/.claude/agents/code-reviewer.md"
rex_template=$(awk '/^## Output Format$/{section=1; next}
  section && /^```markdown$/{template=1; next}
  template && /^```$/{exit}
  template {print}' "$REX_FILE")
heading_drift=0
while IFS= read -r heading; do
  [ -z "$heading" ] && continue
  if ! printf '%s\n' "$rex_template" | grep -qE "^${heading}"; then
    echo "missing from Rex template: $heading" >&2
    heading_drift=1
  fi
done <<EOF
${_REVIEW_REX_BODY_HEADINGS}
EOF
if [ "$heading_drift" -eq 0 ]; then
  mark_pass "required headings appear in the Rex Output Format template"
else
  mark_fail "heading template lock" "lib headings drifted from the agent template"
fi

echo
echo "===== test_validate_rex_review_body.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED"
  exit 1
fi
exit 0

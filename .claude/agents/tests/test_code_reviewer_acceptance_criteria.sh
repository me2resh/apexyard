#!/bin/bash
# Pins Rex's acceptance-criteria check (me2resh/apexyard#1378).
#
# Every review reads the linked issues. It reports each acceptance criterion
# as Met, Not met, or Not verifiable, with evidence. A Not met criterion
# blocks approval. The review-body validator is unchanged. These checks also
# confirm that a body with the new section still passes that validator, and
# that the Not met path writes no marker.

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REX="$ROOT/.claude/agents/code-reviewer.md"
SKILL="$ROOT/.claude/skills/code-review/SKILL.md"
LIB="$ROOT/.claude/hooks/_lib-review-markers.sh"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
not() { ! "$@"; }
has_text() { grep -qF -- "$2" "$1"; }

# Text of the Rex Output Format template only.
rex_template() {
  awk '/^## Output Format$/{section=1; next}
       section && /^```markdown$/{template=1; next}
       template && /^```$/{exit}
       template {print}' "$1"
}
template_has() { rex_template "$1" | grep -qF -- "$2"; }

# Text of the Rex checklist section only, not the template.
checklist_has_ac_section() {
  awk '/^## Review Checklist$/{section=1; next}
       section && /^## /{exit}
       section {print}' "$1" | grep -qF '### Acceptance Criteria — ⛔ BLOCKING CHECK'
}

echo "== Rex agent"
check "Rex checklist has a blocking acceptance-criteria section" checklist_has_ac_section "$REX"
check "Rex runs the check on every review" has_text "$REX" 'Run this check on every review, including re-reviews and reduced-scope reviews.'
check "Rex finds linked issues from Refs and Closes" has_text "$REX" 'Read the PR title and body for `Closes #N`, `Fixes #N`, `Resolves #N`, `Refs #N`, and `owner/repo#N`.'
check "Rex reads each issue with an explicit repo" has_text "$REX" 'gh issue view <N> --repo <owner/repo> --comments'
check "Rex defines Met with evidence" has_text "$REX" '**Met** — the diff, a test, or a command result shows it.'
check "Rex defines Not met" has_text "$REX" '**Not met** — the diff does not satisfy it, or contradicts it.'
check "Rex defines Not verifiable" has_text "$REX" '**Not verifiable** — a review cannot check it'
check "Not met is blocking" has_text "$REX" 'A **Not met** criterion is a blocking finding.'
check "Not met means CHANGES REQUESTED and no marker" has_text "$REX" 'The verdict is CHANGES REQUESTED. Do not write the approval marker.'
check "Met requires evidence" has_text "$REX" 'Do not mark a criterion Met without evidence.'
check "Rex reports a PR with no linked issue" has_text "$REX" 'If the PR links no issue, write "No linked issue"'
check "Rex reports an issue with no criteria" has_text "$REX" 'write "No acceptance criteria in #N"'
check "reduced scope keeps the check" has_text "$REX" 'acceptance criteria (§ "Acceptance Criteria", blocking), PR description quality'
check "process reads linked issues before the checklist" has_text "$REX" '3. Read each linked issue and list its acceptance criteria'
check "output keeps the section" has_text "$REX" 'Summary, Acceptance Criteria, Checklist Results'
check "rules list the check as blocking" has_text "$REX" '**Acceptance criteria are BLOCKING**'
check "template has the section heading" template_has "$REX" '### Acceptance Criteria'
check "template has the per-criterion table" template_has "$REX" '| Issue | Criterion | Status | Evidence |'

echo "== /code-review skill"
check "skill checklist has the blocking section" has_text "$SKILL" '### Acceptance Criteria — BLOCKING'
check "skill reads linked issues with an explicit repo" has_text "$SKILL" 'gh issue view <N> --repo <owner/repo> --comments'
check "skill names the three statuses" has_text "$SKILL" 'Met, Not met, or Not verifiable, with evidence'
check "skill blocks on Not met" has_text "$SKILL" 'A Not met criterion requires CHANGES REQUESTED'
check "skill output lists the criteria" has_text "$SKILL" '- Acceptance criteria: each criterion of each linked issue'

echo "== Unchanged validator accepts the new section"
# shellcheck source=/dev/null
. "$LIB"
SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

write_body() {
  local dest="$1" status="$2" verdict="$3"
  cat > "$dest" <<EOF
${verdict}. Next action follows the verdict.

## Code Review: PR #1

**Commit**: \`${SHA}\`
**Scope**: \`Full\`

### Summary
Adds a field to the export.

### Acceptance Criteria

| Issue | Criterion | Status | Evidence |
|-------|-----------|--------|----------|
| #1 | The export has a date field | Met | src/export.ts:12 |
| #1 | The date uses ISO 8601 | Met | test_export_date passes |
| #1 | The export has a total row | ${status} | No total row in the diff |

### Checklist Results
- Architecture & Design: N/A — fixture

### Issues Found
None

### Validation
fixture

### Verdict
**${verdict}**

---
🤖 Reviewed by Rex (Code Reviewer Agent)
📌 Reviewed commit: \`${SHA}\`
EOF
}

write_body "$TMP/met.md" "Met" "APPROVED"
check "a body with the section passes review_validate_rex_body" review_validate_rex_body "$TMP/met.md"
check "an all-Met APPROVED body writes the marker" review_write_rex_approved "$TMP/met.md" "$SHA" "$TMP/reviews/met-rex.approved"

# Negative case from the issue: two of three criteria met.
write_body "$TMP/not-met.md" "Not met" "CHANGES REQUESTED"
check "a Not met review with CHANGES REQUESTED writes no marker" not review_write_rex_approved "$TMP/not-met.md" "$SHA" "$TMP/reviews/not-met-rex.approved"
check "no marker file exists after the refused write" not test -e "$TMP/reviews/not-met-rex.approved"

printf '\nAcceptance-criteria checks completed with %s failure(s).\n' "$FAIL"
[ "$FAIL" -eq 0 ]

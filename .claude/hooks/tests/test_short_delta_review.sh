#!/usr/bin/env bash
# Test the short posted format against the unchanged production validator.
set -euo pipefail
# shellcheck source=./_test-session-isolation.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=../_lib-review-markers.sh
. "$ROOT/.claude/hooks/_lib-review-markers.sh"
BODY=$(mktemp)
trap 'rm -f "$BODY" "$BODY.bad"' EXIT
cat > "$BODY" <<'BODY'
## Code Review: PR #1773
**Commit**: `1111111111111111111111111111111111111111`
**Scope**: Delta re-review, `0000000..1111111`
### Summary
The delta fixes finding B1. Acceptance criterion AC1 is Met by the current regression test.
### Checklist Results
Testing: Pass, regression suite 2/2. Architecture, quality, performance: N/A, unchanged prose.
Security: N/A, no trust-chain path. PR description and Glossary: Pass, inspected.
Narrative: Pass, explains the fix. AgDR, handbooks, Fallow: N/A, no applicable change.
### Issues Found
B1 resolved by the corrected count. No new finding.
### Validation
Current: regression suite 2/2. Prior review 123 covers unchanged code. No runtime test applies.
### Verdict
**APPROVED**
B1 is resolved. Request the human merge decision.
---
Reviewed by Rex
Reviewed commit: `1111111111111111111111111111111111111111`
BODY
review_validate_rex_body "$BODY"
printf '%s\n' 'PASS: short delta satisfies the production validator'
count=1
while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  awk -v h="$heading" '$0 != h' "$BODY" > "$BODY.bad"
  if review_validate_rex_body "$BODY.bad" >/dev/null 2>&1; then
    printf 'FAIL: missing %s was accepted\n' "$heading"
    exit 1
  fi
  count=$((count + 1))
done <<'HEADINGS'
## Code Review: PR #1773
### Summary
### Checklist Results
### Issues Found
### Validation
### Verdict
HEADINGS
printf '%s passed, 0 failed\n' "$count"

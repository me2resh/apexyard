#!/usr/bin/env bash
# /geo-audit smoke test
#
# Verifies the documentation contracts the consuming surface depends on:
#
#   1. SKILL.md frontmatter sanity (name, argument-hint, effort)
#   2. SKILL.md names all 6 check buckets
#   3. SKILL.md contains the verbatim `skill.md` vs `SKILL.md` naming-clash callout
#   4. SKILL.md cross-links to /seo-audit, /launch-check, AgDR-0043, the registry
#   5. AgDR-0043 exists at the canonical path with body-H1 + no YAML frontmatter
#   6. AgDR-0043 has the four canonical sections (Context, Options Considered,
#      Decision, Consequences) AND the "In the context of..." one-liner
#   7. AgDR-0043 names the GEO/AEO sub-scope distinction + naming-clash callout
#   8. AgDR-0043 references the registry file path
#   9. AI-crawler registry exists at .claude/registries/ai-crawlers.json,
#      valid JSON, lists all 11 named crawlers from the ticket
#  10. Audit template exists at templates/audits/geo-audit.md
#  11. CLAUDE.md skill count is 53 AND /geo-audit row is present
#  12. docs/multi-project.md skill-behaviour table has /geo-audit row
#  13. /seo-audit SKILL.md cross-links to /geo-audit
#  14. /launch-check SKILL.md references /geo-audit in the
#      deep-dive companions table (so the fan-out claim is testable)
#  15. /launch-check SKILL.md description mentions generative-engine
#  16. /launch-check SKILL.md sweep size updated 8 → 9
#
# The skill itself runs inside Claude Code (interactive audit + persistence).
# This smoke test verifies the *documentation contracts* — if any drifts,
# the skill's promise to adopters breaks.

set -uo pipefail

PASS=0
FAIL=0
FAILED_CASES=""

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (pattern: $pattern; file: $file)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

assert_grep_fixed() {
  local label="$1"
  local needle="$2"
  local file="$3"
  if grep -qF "$needle" "$file" 2>/dev/null; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (needle: $needle; file: $file)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  fi
}

assert_not_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo "  FAIL: $label (pattern UNEXPECTEDLY matched: $pattern; file: $file)"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  $label"
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# Resolve the ops-fork root. From inside the skill's tests/ dir, walk up
# until we hit the dir containing the SKILL we're testing.
script_dir="$(cd "$(dirname "$0")" && pwd)"
ops_root="$script_dir"
while [ "$ops_root" != "/" ] && [ ! -f "$ops_root/CLAUDE.md" ]; do
  ops_root=$(dirname "$ops_root")
done
if [ ! -f "$ops_root/CLAUDE.md" ]; then
  echo "FAIL: could not locate ops-fork root (CLAUDE.md missing)"
  exit 1
fi

echo "Smoke test: /geo-audit contract checks (ops_root=$ops_root)"
echo ""

SKILL="$ops_root/.claude/skills/geo-audit/SKILL.md"
AGDR="$ops_root/docs/agdr/AgDR-0043-geo-audit-skill.md"
REGISTRY="$ops_root/.claude/registries/ai-crawlers.json"
TEMPLATE="$ops_root/templates/audits/geo-audit.md"
SEO_SKILL="$ops_root/.claude/skills/seo-audit/SKILL.md"
LAUNCH_SKILL="$ops_root/.claude/skills/launch-check/SKILL.md"
CLAUDEMD="$ops_root/CLAUDE.md"
MULTIPROJECT="$ops_root/docs/multi-project.md"

# ---------------------------------------------------------------------------
# 1. SKILL.md frontmatter sanity
# ---------------------------------------------------------------------------
echo "1. SKILL.md frontmatter sanity:"
[ -f "$SKILL" ] || { echo "FAIL: SKILL.md missing at $SKILL"; exit 1; }
assert_grep "name field present"           "^name: geo-audit"  "$SKILL"
assert_grep "argument-hint field present"  "^argument-hint:"                  "$SKILL"
assert_grep "effort field present"         "^effort:"                         "$SKILL"
assert_grep "description names LLM/agent"  "LLM/agent|LLM crawler"           "$SKILL"
assert_grep "description names GEO"        "GEO"                              "$SKILL"
assert_grep "description names AEO"        "AEO"                              "$SKILL"

# ---------------------------------------------------------------------------
# 2. SKILL.md names all 6 check buckets
# ---------------------------------------------------------------------------
echo ""
echo "2. SKILL.md names all 6 check buckets:"
assert_grep "Discovery bucket"           "Discovery"           "$SKILL"
assert_grep "Capability-signaling bucket" "Capability-signaling" "$SKILL"
assert_grep "Content-format bucket"      "Content-format"      "$SKILL"
assert_grep "Token-economics bucket"     "Token-economics"     "$SKILL"
assert_grep "Analytics bucket"           "Analytics"           "$SKILL"
assert_grep "UX bucket"                  "UX"                  "$SKILL"

# ---------------------------------------------------------------------------
# 3. SKILL.md contains the verbatim skill.md vs SKILL.md naming-clash callout
# ---------------------------------------------------------------------------
echo ""
echo "3. SKILL.md verbatim naming-clash callout:"
assert_grep_fixed "Naming clash phrase present" \
  "distinct from Claude Code's \`SKILL.md\`" "$SKILL"

# ---------------------------------------------------------------------------
# 4. SKILL.md cross-links
# ---------------------------------------------------------------------------
echo ""
echo "4. SKILL.md cross-links:"
assert_grep "Links to /seo-audit"       "/seo-audit"                              "$SKILL"
assert_grep "Links to /launch-check"    "/launch-check"                           "$SKILL"
assert_grep "Links to AgDR-0043"        "AgDR-0043"                               "$SKILL"
assert_grep "Names the registry file"   "\\.claude/registries/ai-crawlers\\.json" "$SKILL"

# ---------------------------------------------------------------------------
# 5. AgDR-0043 file exists, body-H1, no YAML frontmatter
# ---------------------------------------------------------------------------
echo ""
echo "5. AgDR-0043 shape — body-H1, no YAML frontmatter:"
[ -f "$AGDR" ] || { echo "FAIL: AgDR-0043 missing at $AGDR"; exit 1; }
# First line must be H1 starting with "# AgDR-0043"
first_line=$(head -1 "$AGDR")
if [[ "$first_line" =~ ^\#\ AgDR-0043 ]]; then
  echo "  PASS: First line is H1 body-style ($first_line)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: First line not H1 body-style (got: $first_line)"
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  AgDR-0043 first-line H1"
fi
# No YAML frontmatter — assert there's no `---` on line 1
assert_not_grep "No YAML frontmatter opener" "^---" "$AGDR"

# ---------------------------------------------------------------------------
# 6. AgDR-0043 has four sections + "In the context of" opener
# ---------------------------------------------------------------------------
echo ""
echo "6. AgDR-0043 canonical sections + 'In the context of' opener:"
assert_grep "Context section"             "^## Context"             "$AGDR"
assert_grep "Options Considered section"  "^## Options Considered"  "$AGDR"
assert_grep "Decision section"            "^## Decision"            "$AGDR"
assert_grep "Consequences section"        "^## Consequences"        "$AGDR"
assert_grep "'In the context of' opener"  "^> In the context of "   "$AGDR"

# ---------------------------------------------------------------------------
# 7. AgDR-0043 names GEO/AEO distinction + naming-clash
# ---------------------------------------------------------------------------
echo ""
echo "7. AgDR-0043 names GEO/AEO sub-scope distinction + naming clash:"
assert_grep "Names GEO"                            "GEO"                       "$AGDR"
assert_grep "Names AEO"                            "AEO"                       "$AGDR"
assert_grep "Names the naming clash"               "naming clash"              "$AGDR"
assert_grep_fixed "Names skill.md vs SKILL.md"     "skill.md"                  "$AGDR"

# ---------------------------------------------------------------------------
# 8. AgDR-0043 references registry file
# ---------------------------------------------------------------------------
echo ""
echo "8. AgDR-0043 references the registry file:"
assert_grep "Registry file referenced" "ai-crawlers\\.json" "$AGDR"

# ---------------------------------------------------------------------------
# 9. Registry file exists, valid JSON, has all named crawlers from the ticket
# ---------------------------------------------------------------------------
echo ""
echo "9. AI-crawler registry — valid JSON + 11 named crawlers from the ticket:"
[ -f "$REGISTRY" ] || { echo "FAIL: registry missing at $REGISTRY"; exit 1; }

# Validity check
if command -v jq >/dev/null 2>&1; then
  if jq empty "$REGISTRY" 2>/dev/null; then
    echo "  PASS: Registry is valid JSON"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: Registry is NOT valid JSON"
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  Registry JSON validity"
  fi

  # Each named v1 crawler from the ticket
  for crawler in GPTBot ChatGPT-User ClaudeBot Claude-Web anthropic-ai \
                 Google-Extended PerplexityBot CCBot Bytespider \
                 Applebot-Extended cohere-ai; do
    if jq -e --arg ua "$crawler" '.crawlers[] | select(.user_agent == $ua)' "$REGISTRY" >/dev/null 2>&1; then
      echo "  PASS: Registry contains crawler '$crawler'"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: Registry missing crawler '$crawler'"
      FAIL=$((FAIL + 1))
      FAILED_CASES="$FAILED_CASES\n  Registry missing $crawler"
    fi
  done
else
  # Fallback to grep when jq is unavailable
  echo "  (jq not present — falling back to grep-based assertions)"
  for crawler in GPTBot ChatGPT-User ClaudeBot Claude-Web anthropic-ai \
                 Google-Extended PerplexityBot CCBot Bytespider \
                 Applebot-Extended cohere-ai; do
    assert_grep_fixed "Registry contains crawler '$crawler'" "\"$crawler\"" "$REGISTRY"
  done
fi

# ---------------------------------------------------------------------------
# 10. Audit template exists
# ---------------------------------------------------------------------------
echo ""
echo "10. Audit template exists at the canonical path:"
[ -f "$TEMPLATE" ] || { echo "FAIL: template missing at $TEMPLATE"; exit 1; }
assert_grep "Template has H1"            "^# GEO Audit"     "$TEMPLATE"
assert_grep "Template has Findings hdr"  "^## Findings"     "$TEMPLATE"

# ---------------------------------------------------------------------------
# 11. CLAUDE.md skill count + row
# ---------------------------------------------------------------------------
echo ""
echo "11. CLAUDE.md skill count is 53 + /geo-audit row present:"
assert_grep "Skill count is 53"   "^### Available skills \\(53\\)"     "$CLAUDEMD"
assert_grep "Skill row present"   "^\\| \`/geo-audit\`"                 "$CLAUDEMD"

# ---------------------------------------------------------------------------
# 12. docs/multi-project.md skill-behaviour table has the new row
# ---------------------------------------------------------------------------
echo ""
echo "12. docs/multi-project.md skill-behaviour table has /geo-audit row:"
assert_grep "Row present in multi-project" "^\\| \`/geo-audit\`" "$MULTIPROJECT"

# ---------------------------------------------------------------------------
# 13. /seo-audit cross-links to /geo-audit
# ---------------------------------------------------------------------------
echo ""
echo "13. /seo-audit SKILL.md cross-links to /geo-audit:"
assert_grep "/seo-audit links to sibling" "/geo-audit" "$SEO_SKILL"

# ---------------------------------------------------------------------------
# 14. /launch-check references /geo-audit in deep-dive table
# ---------------------------------------------------------------------------
echo ""
echo "14. /launch-check SKILL.md references /geo-audit:"
assert_grep "/launch-check references geo-audit" \
  "/geo-audit" "$LAUNCH_SKILL"

# ---------------------------------------------------------------------------
# 15. /launch-check description mentions generative-engine
# ---------------------------------------------------------------------------
echo ""
echo "15. /launch-check description mentions generative-engine:"
assert_grep "/launch-check description names the new dimension" \
  "generative-engine" "$LAUNCH_SKILL"

# ---------------------------------------------------------------------------
# 16. /launch-check sweep size updated 8 → 9
# ---------------------------------------------------------------------------
echo ""
echo "16. /launch-check sweep size updated to 9 dimensions:"
assert_grep "9-dimension sweep claim"  "9-dimension sweep|9 dimensions"  "$LAUNCH_SKILL"
# And ensure the obsolete "8-dimension sweep" wording is gone
assert_not_grep "Obsolete 8-dimension sweep wording" "8-dimension sweep" "$LAUNCH_SKILL"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "================================================================"

if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$FAILED_CASES"
  exit 1
fi
echo "OK: all /geo-audit smoke checks passed."
exit 0

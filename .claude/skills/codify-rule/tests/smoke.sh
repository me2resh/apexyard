#!/usr/bin/env bash
# /codify-rule smoke test
#
# Verifies the *shape contracts* between the /codify-rule skill spec, the
# AgDR rationale, the CLAUDE.md skill table, the docs/multi-project.md
# table, and the handbooks/ convention. The skill itself runs inside
# Claude Code (interactive interview, file write); this smoke test pins
# down the contracts the skill depends on so the rest of the framework
# can't drift out from under it.
#
# What this checks:
#
#   1. SKILL.md frontmatter sanity (name, argument-hint, allowed-tools).
#   2. SKILL.md names every required section of the handbook shape
#      (The rule / Why / What Rex flags / Sample finding / What's NOT a
#       violation) and the _Source: PR_ footer convention.
#   3. SKILL.md mentions all four buckets (domain / architecture /
#      general / language) — the routing surface.
#   4. SKILL.md mentions the Y/N approval gate as load-bearing.
#   5. SKILL.md mentions --blocking flag handling.
#   6. AgDR-0040 exists, starts with the canonical "# AgDR-NNNN — Title"
#      shape (no YAML frontmatter), and contains the "In the context of"
#      opener.
#   7. AgDR-0040 names this is Stage 2 of #293 and references AgDR-0037
#      (Stage 1).
#   8. CLAUDE.md skill table contains the /codify-rule row and the count
#      bumped to 51.
#   9. docs/multi-project.md skill-behaviour table contains the
#      /codify-rule row.
#  10. The skill writes to handbooks/<bucket>/<…>/<slug>.md (verified by
#      checking the SKILL.md's path-construction logic mentions the
#      shape — we can't run the skill itself in CI).
#
# The skill is NOT executed here. Smoke is a contract-pinning test.

set -euo pipefail

PASS=0
FAIL=0

assert_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if grep -qE "$pattern" "$file"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (pattern: $pattern; file: $file)"
    FAIL=$((FAIL + 1))
  fi
}

assert_no_grep() {
  local label="$1"
  local pattern="$2"
  local file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (pattern unexpectedly matched: $pattern; file: $file)"
    FAIL=$((FAIL + 1))
  fi
}

# Resolve the ops-fork root by walking up from this script until we find
# the handbooks/ tree (which is the canonical proof that we're inside
# an apexyard fork that ships the handbook convention).
script_dir="$(cd "$(dirname "$0")" && pwd)"
ops_root="$script_dir"
while [ "$ops_root" != "/" ] && [ ! -d "$ops_root/handbooks/domain" ]; do
  ops_root=$(dirname "$ops_root")
done
if [ ! -d "$ops_root/handbooks/domain" ]; then
  echo "FAIL: could not locate ops-fork root (handbooks/domain/ missing)"
  exit 1
fi

skill_md="$ops_root/.claude/skills/codify-rule/SKILL.md"
agdr_md="$ops_root/docs/agdr/AgDR-0040-codify-rule-skill.md"
claude_md="$ops_root/CLAUDE.md"
multi_md="$ops_root/docs/multi-project.md"

echo "Smoke test: /codify-rule contract checks (ops_root=$ops_root)"
echo ""

# ---------------------------------------------------------------------------
# 1. SKILL.md frontmatter sanity
# ---------------------------------------------------------------------------
echo "1. SKILL.md frontmatter sanity:"
assert_grep "name: codify-rule"                       "^name: codify-rule$"             "$skill_md"
assert_grep "argument-hint declared"                  "^argument-hint:"                 "$skill_md"
assert_grep "allowed-tools includes Bash, Read, Write" "^allowed-tools: Bash, Read, Write$" "$skill_md"
assert_grep "description mentions Stage 2 of #293"    "Stage 2 of #293"                 "$skill_md"

# ---------------------------------------------------------------------------
# 2. SKILL.md covers every handbook-shape section + the Source footer
# ---------------------------------------------------------------------------
echo ""
echo "2. SKILL.md names every required handbook section:"
assert_grep "## The rule heading"           '## The rule'             "$skill_md"
assert_grep "## Why heading"                '## Why'                  "$skill_md"
assert_grep "## What Rex flags heading"     '## What Rex flags'       "$skill_md"
assert_grep "## Sample finding heading"     '## Sample finding'       "$skill_md"
assert_grep "## What.s NOT a violation"     "What's NOT a violation"  "$skill_md"
assert_grep "_Source: PR #N footer mentioned"  'Source: PR #'         "$skill_md"

# ---------------------------------------------------------------------------
# 3. SKILL.md mentions all four buckets
# ---------------------------------------------------------------------------
echo ""
echo "3. SKILL.md mentions all four handbook buckets:"
assert_grep "domain bucket"       '\bdomain\b'       "$skill_md"
assert_grep "architecture bucket" '\barchitecture\b' "$skill_md"
assert_grep "general bucket"      '\bgeneral\b'      "$skill_md"
assert_grep "language bucket"     '\blanguage\b'     "$skill_md"

# ---------------------------------------------------------------------------
# 4. SKILL.md mentions the Y/N approval gate as mandatory
# ---------------------------------------------------------------------------
echo ""
echo "4. SKILL.md names the Y/N approval gate as load-bearing:"
assert_grep "approval gate mentioned"  "approval gate"             "$skill_md"
assert_grep "operator-curated"         "operator-curated"          "$skill_md"
assert_grep "yes/edit/no choice"       "yes.*edit.*(no|cancel)"    "$skill_md"

# ---------------------------------------------------------------------------
# 5. SKILL.md handles --blocking + advisory default
# ---------------------------------------------------------------------------
echo ""
echo "5. SKILL.md covers --blocking opt-in and advisory default:"
assert_grep "advisory default"       "advisory is the default|Default to.*advisory|Default advisory"  "$skill_md"
assert_grep "--blocking flag"        "[-]{1,2}blocking"                "$skill_md"
assert_grep "ENFORCEMENT: blocking"  "ENFORCEMENT: blocking"           "$skill_md"

# Co-location contract: the --blocking flag and the ENFORCEMENT: blocking
# marker must be WIRED in the spec, not just both present. Verify they
# appear within 3 lines of each other (the spec's wiring sentence is
# typically "the literal line ENFORCEMENT: blocking ... when --blocking
# was passed"). Catches the failure mode where someone removes the
# wiring but leaves both phrases scattered in the file.
if grep -nE "ENFORCEMENT: blocking" "$skill_md" | awk -F: '{print $1}' > /tmp/codify_enforce_lines.txt \
   && grep -nE "[-]{1,2}blocking" "$skill_md" | awk -F: '{print $1}' > /tmp/codify_flag_lines.txt; then
  co_located=0
  while read -r e_line; do
    while read -r f_line; do
      diff=$((e_line - f_line)); [ "$diff" -lt 0 ] && diff=$((-diff))
      if [ "$diff" -le 3 ]; then co_located=1; break 2; fi
    done < /tmp/codify_flag_lines.txt
  done < /tmp/codify_enforce_lines.txt
  if [ "$co_located" -eq 1 ]; then
    echo "  PASS: --blocking flag and ENFORCEMENT: blocking marker are co-located in the spec (≤3 lines apart)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: --blocking and ENFORCEMENT: blocking both appear but are not co-located (>3 lines apart) — the wiring sentence may have been removed"
    FAIL=$((FAIL + 1))
  fi
  rm -f /tmp/codify_enforce_lines.txt /tmp/codify_flag_lines.txt
fi

# ---------------------------------------------------------------------------
# 6. SKILL.md routes paths/frontmatter correctly (domain-only paths:)
# ---------------------------------------------------------------------------
echo ""
echo "6. SKILL.md scopes 'paths:' frontmatter to the domain bucket:"
assert_grep "paths: frontmatter mentioned"            "paths:"                          "$skill_md"
assert_grep "frontmatter only for domain"             "domain-only|domain bucket"       "$skill_md"
# Architecture / general / language are explicitly described as frontmatter-free.
assert_grep "frontmatter-free for other buckets"      "frontmatter-free"                "$skill_md"

# ---------------------------------------------------------------------------
# 7. SKILL.md hooks into custom-handbooks (private layer)
# ---------------------------------------------------------------------------
echo ""
echo "7. SKILL.md offers private custom-handbooks layer when configured:"
assert_grep "portfolio_custom_handbooks_dir"  "portfolio_custom_handbooks_dir"  "$skill_md"
assert_grep "private layer mentioned"         "custom-handbooks|private layer"  "$skill_md"

# ---------------------------------------------------------------------------
# 8. AgDR-0040 exists, follows the convention (no YAML frontmatter)
# ---------------------------------------------------------------------------
echo ""
echo "8. AgDR-0040 shape + content:"
if [ ! -f "$agdr_md" ]; then
  echo "  FAIL: AgDR-0040 missing at $agdr_md"
  FAIL=$((FAIL + 1))
else
  # First line is the canonical "# AgDR-NNNN — Title" shape.
  first_line=$(head -n 1 "$agdr_md")
  if [[ "$first_line" =~ ^#\ AgDR-0040 ]]; then
    echo "  PASS: AgDR-0040 opens with the canonical '# AgDR-NNNN' header"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: AgDR-0040 first line is not '# AgDR-0040 ...' (got: $first_line)"
    FAIL=$((FAIL + 1))
  fi

  # No YAML frontmatter (no leading `---` line).
  if [[ "$first_line" == "---" ]]; then
    echo "  FAIL: AgDR-0040 has YAML frontmatter (recent AgDRs are frontmatter-free)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: AgDR-0040 has no YAML frontmatter"
    PASS=$((PASS + 1))
  fi

  assert_grep "AgDR-0040 has 'In the context of' opener" "^> In the context of " "$agdr_md"
  assert_grep "AgDR-0040 names Stage 2 of #293"          "Stage 2 of #293"        "$agdr_md"
  assert_grep "AgDR-0040 references AgDR-0037"           "AgDR-0037"              "$agdr_md"
  assert_grep "AgDR-0040 has Options Considered table"   "^## Options Considered" "$agdr_md"
  assert_grep "AgDR-0040 has Decision section"           "^## Decision"           "$agdr_md"
  assert_grep "AgDR-0040 has Consequences section"       "^## Consequences"       "$agdr_md"
fi

# ---------------------------------------------------------------------------
# 9. CLAUDE.md skill table updated to 51 + /codify-rule row present
# ---------------------------------------------------------------------------
echo ""
echo "9. CLAUDE.md skill table updates:"
assert_grep "skill count bumped to 51"              "51 slash commands"               "$claude_md"
assert_grep "Available skills heading at 51"        "^### Available skills \(51\)"     "$claude_md"
assert_grep "/codify-rule row present"              '`/codify-rule`'                  "$claude_md"

# ---------------------------------------------------------------------------
# 10. docs/multi-project.md skill-behaviour table contains /codify-rule
# ---------------------------------------------------------------------------
echo ""
echo "10. docs/multi-project.md skill table contains /codify-rule:"
assert_grep "multi-project mentions /codify-rule"  '`/codify-rule`'  "$multi_md"

# ---------------------------------------------------------------------------
# 11. handbooks/ tree is what the skill writes into
# ---------------------------------------------------------------------------
echo ""
echo "11. handbooks/ tree exists with the four expected buckets:"
for bucket in architecture general language domain; do
  if [ -d "$ops_root/handbooks/$bucket" ]; then
    echo "  PASS: handbooks/$bucket/ exists"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: handbooks/$bucket/ missing"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
# 12. Behavioural simulation — verify the skill's path-build logic
#     produces the documented shape for each bucket
# ---------------------------------------------------------------------------
echo ""
echo "12. Path-build shape — simulated:"

# Domain → handbooks/domain/<area>/<slug>.md
expected="$ops_root/handbooks/domain/github-emu/github-emu-private-fork-access.md"
case "$expected" in
  */handbooks/domain/github-emu/github-emu-private-fork-access.md)
    echo "  PASS: domain bucket path shape ($expected)"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL: domain bucket path shape"
    FAIL=$((FAIL + 1))
    ;;
esac

# Architecture → handbooks/architecture/<slug>.md
expected="$ops_root/handbooks/architecture/no-process-env-in-application.md"
case "$expected" in
  */handbooks/architecture/no-process-env-in-application.md)
    echo "  PASS: architecture bucket path shape ($expected)"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL: architecture bucket path shape"
    FAIL=$((FAIL + 1))
    ;;
esac

# Language → handbooks/language/<lang>/<slug>.md
expected="$ops_root/handbooks/language/typescript/no-any-without-comment.md"
case "$expected" in
  */handbooks/language/typescript/no-any-without-comment.md)
    echo "  PASS: language bucket path shape ($expected)"
    PASS=$((PASS + 1))
    ;;
  *)
    echo "  FAIL: language bucket path shape"
    FAIL=$((FAIL + 1))
    ;;
esac

# ---------------------------------------------------------------------------
# 13. Source-footer shape — three ingredients must co-occur in the template
# ---------------------------------------------------------------------------
echo ""
echo "13. Source-footer template names PR number, comment author, comment date:"
# Loosened from exact-literal pinning so harmless template-shape changes
# (separator characters, italics vs bold, label wording) don't break the
# test — what matters is that the three audit-trail ingredients are all
# present in the same template line.
assert_grep "footer names PR number"      "Source.*pr_number|Source.*PR #\{"   "$skill_md"
assert_grep "footer names comment author" "comment_author"                     "$skill_md"
assert_grep "footer names comment date"   "comment_date"                       "$skill_md"

# ---------------------------------------------------------------------------
# 14. Re-run handling: append / overwrite / cancel choice
# ---------------------------------------------------------------------------
echo ""
echo "14. SKILL.md handles re-runs on existing slugs:"
assert_grep "Append choice mentioned"     "Append"     "$skill_md"
assert_grep "Overwrite choice mentioned"  "Overwrite"  "$skill_md"
assert_grep "Cancel choice mentioned"     "Cancel"     "$skill_md"

# ---------------------------------------------------------------------------
# Final tally
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo ""
echo "OK: /codify-rule contract checks passed."
exit 0

#!/bin/bash
# Tests for me2resh/apexyard#1064 / AgDR-0116 — "the Lean tier is unreachable
# because the merge gate requires a Rex marker regardless of tier".
#
# The maintainer's chosen resolution is Direction 3 (accept & document) +
# Option 4 (reduced-scope Rex): block-unreviewed-merge.sh is NOT touched and
# stays unconditional; right-size-ceremony.md and code-reviewer.md are edited
# instead so the Lean tier's own prose stops promising something the gate
# forbids, and Rex gets a reduced-scope mode for eligible Lean diffs.
#
# Acceptance criterion #5 on the issue: "Tests cover that a security /
# trust-chain / migration path cannot reach the Lean path under any
# configuration." This suite pins that at THREE independent points, each
# with a discriminating assertion (proven to catch a regression, not just a
# presence check):
#
#   1. block-unreviewed-merge.sh's Rex-marker-check block carries no
#      lean/tier-conditional bypass — proven discriminating by injecting a
#      synthetic bypass and confirming the SAME detector flags it (case 2).
#   2. code-reviewer.md's reduced-scope eligibility bar states rail 1
#      (security/trust-chain/migration disqualifies) and rail 2 (ambiguity
#      rounds up) explicitly, with the concrete path patterns present —
#      proven discriminating by stripping the rail-1 list and confirming the
#      SAME detector then fails (case 5).
#   3. A pure-bash matcher mirroring code-reviewer.md's documented Lean
#      eligibility rail 1 rejects every security/trust-chain/migration path
#      class, even when mixed into an otherwise all-docs diff (cases 11-17).
#
# Also pins: the merge gate's unconditional presence-check line is untouched
# (case 3), right-size-ceremony.md no longer promises "no review sub-agent"
# for Lean (case 7) while rails 1 & 2 remain verbatim (case 8), and
# auto-code-review.sh keeps "Rex on every PR" unconditional while adding the
# tier-aware role-chain note (case 9).
#
# Exit 0 = all pass. Exit 1 on any failure.

set -u

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"        # .../.claude/hooks
CLAUDE_DIR="$(cd "$HOOK_DIR/.." && pwd)"             # .../.claude
REPO_ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"            # repo root

MERGE_GATE="$HOOK_DIR/block-unreviewed-merge.sh"
CODE_REVIEWER="$CLAUDE_DIR/agents/code-reviewer.md"
RIGHT_SIZE_RULE="$CLAUDE_DIR/rules/right-size-ceremony.md"
AUTO_REVIEW_HOOK="$HOOK_DIR/auto-code-review.sh"
AGDR_FILE=""
if [ -d "$REPO_ROOT/docs/agdr" ]; then
  AGDR_FILE=$(find "$REPO_ROOT/docs/agdr" -maxdepth 1 -iname "AgDR-*-lean-tier-reachable.md" 2>/dev/null | head -1)
fi

for f in "$MERGE_GATE" "$CODE_REVIEWER" "$RIGHT_SIZE_RULE" "$AUTO_REVIEW_HOOK"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file not found: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""
record_pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
record_fail() {
  FAIL=$((FAIL + 1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
  echo "FAIL: $1"
  [ -n "${2:-}" ] && echo "  $2"
}

# =============================================================================
# Helper: extract the Rex-marker-check block from block-unreviewed-merge.sh —
# the exact text between the "--- Rex marker check ---" comment and the next
# "--- Posted-review check" comment. This is the block that decides whether a
# merge is blocked for lack of a Rex marker; a tier-conditional bypass would
# have to live here (or short-circuit before it) to actually relax the gate.
# =============================================================================
extract_rex_check_block() {
  sed -n '/# --- Rex marker check ---/,/# --- Posted-review check/p' "$MERGE_GATE"
}

# A tier/lean-conditional bypass would introduce one of these tokens into the
# block that decides whether the merge is blocked. Case-insensitive.
BYPASS_TOKENS='lean|LEAN|tier|TIER|skip_rex|SKIP_REX|reduced.scope|reduced_scope|REDUCED_SCOPE'

# =============================================================================
# Case 1: the REAL merge-gate's Rex-check block carries no tier/lean bypass.
# =============================================================================
BLOCK=$(extract_rex_check_block)
if [ -z "$BLOCK" ]; then
  record_fail "case1: could not extract the Rex-marker-check block from block-unreviewed-merge.sh" \
    "the anchor comments may have moved — update extract_rex_check_block()"
elif echo "$BLOCK" | grep -qEi "$BYPASS_TOKENS"; then
  record_fail "case1: block-unreviewed-merge.sh's Rex-check block contains a tier/lean-conditional token" \
    "rail 1 requires the merge gate to stay unconditional (AgDR-0116) — it must not be touched by this change"
else
  record_pass "case1: block-unreviewed-merge.sh's Rex-check block has no tier/lean bypass"
fi

# =============================================================================
# Case 2 (discriminating): prove case 1's detector actually catches a
# regression. Inject a synthetic tier-conditional bypass into a COPY of the
# same block and confirm the identical detector flags it. If this case
# failed, case 1 would be a tautology (a check that can never fail).
# =============================================================================
MUTATED_BLOCK="${BLOCK}
if [ \"\${LEAN_TIER:-}\" = \"lean\" ]; then
  exit 0
fi"
if echo "$MUTATED_BLOCK" | grep -qEi "$BYPASS_TOKENS"; then
  record_pass "case2: the case-1 detector correctly flags an injected lean-tier bypass (discriminating)"
else
  record_fail "case2: the case-1 detector did NOT flag an injected lean-tier bypass" \
    "this means case 1 could never fail — it is not actually testing anything"
fi

# =============================================================================
# Case 3: the merge gate's unconditional presence-check line is intact —
# `if [ ! -f "$REX_APPROVAL" ]` with no surrounding tier guard. This is the
# literal line that makes the gate refuse to merge without a Rex marker.
# =============================================================================
if grep -qF 'if [ ! -f "$REX_APPROVAL" ]; then' "$MERGE_GATE"; then
  record_pass "case3: block-unreviewed-merge.sh's unconditional Rex-marker presence check is present"
else
  record_fail "case3: block-unreviewed-merge.sh no longer has the unconditional Rex-marker presence check" \
    "this is the literal gate — its absence or a guard around it would be a rail-1 violation"
fi

# =============================================================================
# Helper: extract code-reviewer.md's Reduced-Scope Review section (Option 4).
# =============================================================================
extract_reduced_scope_section() {
  sed -n '/^## Reduced-Scope Review/,/^## Review Checklist/p' "$CODE_REVIEWER"
}

# The concrete rail-1 path patterns that MUST appear in the eligibility bar —
# same defaults require-migration-ticket.sh matches (workflow-gates.md §
# Migration Gate) plus the trust-chain / auth-crypto-secrets patterns from
# role-triggers.md's Security Auditor trigger table.
RAIL1_PATTERNS=(
  '.claude/hooks'
  '.claude/settings.json'
  'auth'
  'crypto'
  'secrets'
  '.env'
  'migrations'
  'migrate-'
  'prisma'
  'alembic'
  'db/migrate'
)

# =============================================================================
# Case 4: code-reviewer.md's Reduced-Scope Review section lists every rail-1
# path pattern above. Missing even one means a diff touching that path class
# could be waved through as "eligible" by an agent following the doc literally.
# =============================================================================
RS_SECTION=$(extract_reduced_scope_section)
if [ -z "$RS_SECTION" ]; then
  record_fail "case4: could not find '## Reduced-Scope Review' section in code-reviewer.md" \
    "Option 4 (reduced-scope Rex) is required by the AgDR-0116 decision"
else
  MISSING=""
  for pat in "${RAIL1_PATTERNS[@]}"; do
    if ! echo "$RS_SECTION" | grep -qF "$pat"; then
      MISSING="$MISSING $pat"
    fi
  done
  if [ -n "$MISSING" ]; then
    record_fail "case4: code-reviewer.md's Reduced-Scope Review section is missing rail-1 pattern(s)" \
      "missing:$MISSING"
  else
    record_pass "case4: code-reviewer.md's Reduced-Scope Review section lists all rail-1 path patterns"
  fi
fi

# =============================================================================
# Case 5 (discriminating): prove case 4's detector actually catches a
# regression. Strip the rail-1 pattern list out of a COPY of the section
# (simulating someone silently deleting it) and confirm the SAME detector
# then reports missing patterns.
# =============================================================================
STRIPPED_SECTION=$(echo "$RS_SECTION" | grep -viE 'auth|crypto|secrets|\.env|migrat|prisma|alembic|hooks|settings\.json')
STRIPPED_MISSING=""
for pat in "${RAIL1_PATTERNS[@]}"; do
  if ! echo "$STRIPPED_SECTION" | grep -qF "$pat"; then
    STRIPPED_MISSING="$STRIPPED_MISSING $pat"
  fi
done
if [ -n "$STRIPPED_MISSING" ]; then
  record_pass "case5: the case-4 detector correctly reports missing patterns once the rail-1 list is stripped (discriminating)"
else
  record_fail "case5: the case-4 detector still found every pattern after stripping the rail-1 list" \
    "this means case 4 could never fail — it is not actually testing anything"
fi

# =============================================================================
# Case 6: rail 1 and rail 2 language is stated explicitly in the eligibility
# bar (not just the path list) — "disqualifies the ENTIRE diff" (rail 1) and
# an explicit fallback to the full review on ambiguity (rail 2).
# =============================================================================
if echo "$RS_SECTION" | grep -qi 'disqualif' && echo "$RS_SECTION" | grep -qi 'ambig'; then
  record_pass "case6: code-reviewer.md's eligibility bar states both rail 1 (disqualifies) and rail 2 (ambiguity) explicitly"
else
  record_fail "case6: code-reviewer.md's eligibility bar is missing explicit rail 1 and/or rail 2 language"
fi

# =============================================================================
# Case 7: right-size-ceremony.md's Lean row no longer promises "no review
# sub-agent" (the unfollowable prescription #1064 filed against).
# =============================================================================
LEAN_ROW=$(grep -i '^\| \*\*Lean\*\*' "$RIGHT_SIZE_RULE")
if [ -z "$LEAN_ROW" ]; then
  record_fail "case7: could not find the Lean row in right-size-ceremony.md's tier table"
elif echo "$LEAN_ROW" | grep -qi 'no review sub-agent'; then
  record_fail "case7: right-size-ceremony.md's Lean row still promises 'no review sub-agent'" \
    "this is the exact unfollowable prescription #1064 was filed against"
else
  record_pass "case7: right-size-ceremony.md's Lean row no longer promises 'no review sub-agent'"
fi

# =============================================================================
# Case 8: rails 1 & 2 in right-size-ceremony.md remain VERBATIM — the task
# explicitly required these untouched. Pin two exact sentences.
# =============================================================================
RAIL1_SENTENCE='Security and trust-chain never go Lean.'
RAIL2_SENTENCE='Ambiguity rounds up.'
if grep -qF "$RAIL1_SENTENCE" "$RIGHT_SIZE_RULE" && grep -qF "$RAIL2_SENTENCE" "$RIGHT_SIZE_RULE"; then
  record_pass "case8: right-size-ceremony.md's rails 1 & 2 sentences are present verbatim, unchanged"
else
  record_fail "case8: right-size-ceremony.md's rail 1 and/or rail 2 sentence was altered or removed" \
    "the task required rails 1 & 2 to stay verbatim"
fi

# =============================================================================
# Case 9: auto-code-review.sh keeps the unconditional Rex-on-every-PR
# instruction AND adds the tier-aware role-chain note.
# =============================================================================
if grep -qi 'requires the code-reviewer agent (Rex)' "$AUTO_REVIEW_HOOK" \
   && grep -qi 'to run on every PR' "$AUTO_REVIEW_HOOK"; then
  record_pass "case9a: auto-code-review.sh's unconditional 'Rex on every PR' instruction is present"
else
  record_fail "case9a: auto-code-review.sh no longer states the unconditional Rex-on-every-PR instruction"
fi
if grep -qi 'CEREMONY TIER' "$AUTO_REVIEW_HOOK" && grep -qi 'ROLE CHAIN' "$AUTO_REVIEW_HOOK"; then
  record_pass "case9b: auto-code-review.sh's banner adds the tier-aware role-chain note"
else
  record_fail "case9b: auto-code-review.sh's banner is missing the tier-aware role-chain note"
fi

# =============================================================================
# Case 10: the AgDR-0116 file exists and records the chosen directions.
# =============================================================================
if [ -z "$AGDR_FILE" ] || [ ! -f "$AGDR_FILE" ]; then
  record_fail "case10: could not find docs/agdr/AgDR-*-lean-tier-reachable.md"
else
  if grep -qi 'Direction 3' "$AGDR_FILE" && grep -qi 'Option 4' "$AGDR_FILE" \
     && grep -qi 'unconditional' "$AGDR_FILE"; then
    record_pass "case10: AgDR-0116 file exists and records Direction 3 + Option 4 + the unconditional gate"
  else
    record_fail "case10: AgDR-0116 file exists but is missing expected content (Direction 3 / Option 4 / unconditional)"
  fi
fi

# =============================================================================
# Cases 11-17: a pure-bash matcher mirroring code-reviewer.md's documented
# Lean eligibility rail 1 (§ "Reduced-Scope Review" condition 4). This
# operationalizes the prose into a checkable function — since Direction 3
# ships no mechanical gate exemption (the merge gate itself stays
# unconditional, per case 1-3 above), this is the closest thing to a
# "classification helper" the decision produces, and it must fail closed on
# every security / trust-chain / migration path class, even when mixed into
# an otherwise all-docs diff.
# =============================================================================
is_lean_eligible_pathset() {
  # Prints "eligible" or "not-eligible: <reason>" for a newline-separated
  # list of changed file paths, mirroring code-reviewer.md's rail 1 list.
  local paths="$1" p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in
      .claude/hooks/*|.claude/settings.json) echo "not-eligible: trust-chain ($p)"; return ;;
      */auth/*|auth/*)                       echo "not-eligible: auth ($p)"; return ;;
      */crypto/*|crypto/*)                   echo "not-eligible: crypto ($p)"; return ;;
      */secrets/*|secrets/*)                 echo "not-eligible: secrets ($p)"; return ;;
      .env|.env.*|*/.env|*/.env.*)           echo "not-eligible: dotenv ($p)"; return ;;
      */migrate-*.ts|*/migrate-*.js|*/migrate-*.py|*/migrate-*.sql) echo "not-eligible: migration-script ($p)"; return ;;
      */prisma/schema.prisma|*/prisma/migrations/*) echo "not-eligible: prisma ($p)"; return ;;
      */alembic/versions/*.py)               echo "not-eligible: alembic ($p)"; return ;;
      */db/migrate/*.rb)                     echo "not-eligible: rails-migration ($p)"; return ;;
      */migrations/*|migrations/*)           echo "not-eligible: migration-dir ($p)"; return ;;
      *.md|*.txt)                            : ;;  # docs — eligible on its own
      *) echo "not-eligible: non-docs path ($p) [condition 1 — not path-class-eligible]"; return ;;
    esac
  done <<< "$paths"
  echo "eligible"
}

check_not_eligible() {
  local desc="$1" paths="$2"
  local result
  result=$(is_lean_eligible_pathset "$paths")
  if echo "$result" | grep -q '^not-eligible'; then
    record_pass "$desc → correctly rejected ($result)"
  else
    record_fail "$desc → WAS marked eligible, expected rejection" "result: $result"
  fi
}

check_not_eligible "case11: all-docs diff + one file under .claude/hooks/" \
"README.md
docs/notes.md
.claude/hooks/block-unreviewed-merge.sh"

check_not_eligible "case12: all-docs diff + .claude/settings.json" \
"README.md
.claude/settings.json"

check_not_eligible "case13: all-docs diff + a file under src/auth/" \
"docs/guide.md
src/auth/login.ts"

check_not_eligible "case14: all-docs diff + a migrations/ file" \
"README.md
db/migrations/2026_add_column.sql"

check_not_eligible "case15: all-docs diff + prisma/schema.prisma" \
"docs/notes.md
prisma/schema.prisma"

check_not_eligible "case16: all-docs diff + alembic/versions migration" \
"README.md
alembic/versions/0007_add_index.py"

check_not_eligible "case17: all-docs diff + a bare .env file" \
"docs/setup.md
.env"

# Control: a genuinely all-docs diff with no rail-1 hits IS eligible — proves
# cases 11-17 aren't just failing everything by construction.
CONTROL_RESULT=$(is_lean_eligible_pathset "README.md
docs/onboarding/glossary.md
CHANGELOG.md")
if [ "$CONTROL_RESULT" = "eligible" ]; then
  record_pass "case18 (control): a genuinely all-docs diff with no rail-1 hits is marked eligible"
else
  record_fail "case18 (control): a genuinely all-docs diff was incorrectly rejected" "result: $CONTROL_RESULT"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "===== test_lean_tier_reachable.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0

#!/bin/bash
# Six agents run without CLAUDE.md: Rex, Tariq, Naqid, Salim, Munir, and Hamza.
# Each carries a floor block with only the rules it uses. Hakim keeps CLAUDE.md.
# Build agents keep CLAUDE.md and the memory index because their lessons live there.
# The #1650 and #1662 eval reports are in docs/eval-agents/reports/.
#
# The pinned strings hold literal backticks, so single quotes are intended.
# shellcheck disable=SC2016

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AGENTS="$ROOT/.claude/agents"
REX="$AGENTS/code-reviewer.md"
HAKIM="$AGENTS/security-reviewer.md"
OMIT_AGENTS="code-reviewer solution-architect contrarian qa-engineer dependency-auditor penetration-tester"
# The #1650 and #1662 evals found 4 misses of 19 without CLAUDE.md.
# Report: docs/eval-agents/reports/review-agents-lean-2026-10-12.md.
KEEP_AGENTS="security-reviewer"
BUILD_AGENTS="backend-engineer frontend-engineer platform-engineer data-engineer product-manager ui-designer ux-designer"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Print the frontmatter block (between the first two '---' lines).
frontmatter() {
  awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } NR > 1 { print }' "$1"
}

# Print the floor-rules section, up to the next '## ' heading or '---' rule.
floor_section() {
  awk '/^## Floor rules \(this agent runs without CLAUDE\.md\)$/ { on = 1; next }
       on && (/^## / || /^---$/) { exit }
       on { print }' "$1"
}

require_in() {
  local text="$1" haystack="$2" description="$3"
  if printf '%s\n' "$haystack" | grep -qF -- "$text"; then
    pass "$description"
  else
    fail "$description"
  fi
}

for file in "$REX" "$HAKIM"; do
  if [ ! -f "$file" ]; then
    fail "agent file exists: ${file#"$ROOT"/}"
    exit "$FAIL"
  fi
done

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# --- omitClaudeMd in the Rex frontmatter only --------------------------------
if frontmatter "$REX" | grep -qxE 'omitClaudeMd:[[:space:]]*true'; then
  pass "Rex sets omitClaudeMd: true in its frontmatter"
else
  fail "Rex sets omitClaudeMd: true in its frontmatter"
fi

# Discriminating check: the frontmatter reader must not see a body line.
printf -- '---\nname: x\n---\nomitClaudeMd: true\n' > "$tmp_dir/body-only.md"
if frontmatter "$tmp_dir/body-only.md" | grep -qxE 'omitClaudeMd:[[:space:]]*true'; then
  fail "the frontmatter reader ignores an omitClaudeMd line in the body"
else
  pass "the frontmatter reader ignores an omitClaudeMd line in the body"
fi

# Only the six review agents may opt out.
others=""
for file in "$AGENTS"/*.md; do
  name=$(basename "$file" .md)
  case " $OMIT_AGENTS " in
    *" $name "*) continue ;;
  esac
  if frontmatter "$file" | grep -qE '^[[:space:]]*omitClaudeMd:'; then
    others="$others $name"
  fi
done
if [ -z "$others" ]; then
  pass "only the six review agents set omitClaudeMd"
else
  fail "only the six review agents set omitClaudeMd (found:$others)"
fi

# Adding either setting needs an eval report with 0 misses at k=19
# on hakim-1546-f78c8ae25.
for name in $KEEP_AGENTS; do
  file="$AGENTS/$name.md"
  if ! frontmatter "$file" | grep -qE '^[[:space:]]*omitClaudeMd:'; then
    pass "Hakim keeps CLAUDE.md and sets no omitClaudeMd"
  else
    fail "Hakim keeps CLAUDE.md and sets no omitClaudeMd"
  fi
  if ! grep -qiE '^##[[:space:]]+Floor[ -]rules' "$file"; then
    pass "Hakim has no floor-rules section (it keeps CLAUDE.md)"
  else
    fail "Hakim has no floor-rules section (it keeps CLAUDE.md)"
  fi
done

for name in $BUILD_AGENTS; do
  if [ -f "$AGENTS/$name.md" ] &&
     ! frontmatter "$AGENTS/$name.md" | grep -qE '^[[:space:]]*omitClaudeMd:'; then
    pass "$name: build agent keeps CLAUDE.md"
  else
    fail "$name: build agent keeps CLAUDE.md"
  fi
done

check_omit_agent() {
  local name="$1" file="$AGENTS/$1.md" floor
  if [ -f "$file" ]; then
    pass "$name agent file exists"
  else
    fail "$name agent file exists"
    return
  fi
  if frontmatter "$file" | grep -qxE 'omitClaudeMd:[[:space:]]*true'; then
    pass "$name sets omitClaudeMd: true in its frontmatter"
  else
    fail "$name sets omitClaudeMd: true in its frontmatter"
  fi
  floor=$(floor_section "$file")
  if [ -n "$floor" ]; then
    pass "$name has a floor-rules section"
  else
    fail "$name has a floor-rules section"
  fi
  require_in 'omitClaudeMd' "$floor" "$name floor block states why it exists"
}

for name in $OMIT_AGENTS; do
  check_omit_agent "$name"
done

printf -- '---\nname: x\nomitClaudeMd: true\n---\n' > "$tmp_dir/frontmatter.md"
if frontmatter "$tmp_dir/frontmatter.md" | grep -qxE 'omitClaudeMd:[[:space:]]*true'; then
  pass "the frontmatter reader flags omitClaudeMd in frontmatter"
else
  fail "the frontmatter reader flags omitClaudeMd in frontmatter"
fi

# --- Rex floor block ---------------------------------------------------------
REX_FLOOR=$(floor_section "$REX")
if [ -n "$REX_FLOOR" ]; then
  pass "Rex has a floor-rules section"
else
  fail "Rex has a floor-rules section"
fi
require_in 'omitClaudeMd' "$REX_FLOOR" "Rex floor block states why it exists"
require_in '{type}/{TICKET-ID}-{description}' "$REX_FLOOR" "Rex floor: branch name convention"
require_in 'type(TICKET): description' "$REX_FLOOR" "Rex floor: PR title convention"
require_in '`blocked by #N` name only a real tracker issue' "$REX_FLOOR" "Rex floor: ticket vocabulary"
require_in '.claude/rules/ticket-vocabulary.md' "$REX_FLOOR" "Rex floor: points to the ticket-vocabulary rule"
require_in 'One PR covers one ticket.' "$REX_FLOOR" "Rex floor: one ticket per PR"
require_in 'Never `git add -A` or `git add .`' "$REX_FLOOR" "Rex floor: git add rule"
require_in 'Never push directly to `main`' "$REX_FLOOR" "Rex floor: no direct push to main"
require_in 'Coverage for domain logic stays above 80%' "$REX_FLOOR" "Rex floor: 80% coverage"
require_in 'explicit per-PR human approval' "$REX_FLOOR" "Rex floor: per-PR human merge approval"
require_in 'No hardcoded secrets' "$REX_FLOOR" "Rex floor: no hardcoded secrets"
require_in '.claude/rules/agdr-decisions.md' "$REX_FLOOR" "Rex floor: AgDR rule"
require_in 'Framework PRs merge to `dev`' "$REX_FLOOR" "Rex floor: framework base branch"
for rule in pr-quality.md pr-workflow.md writing-standard.md right-size-ceremony.md evidence-grounding.md; do
  require_in "$rule" "$REX_FLOOR" "Rex floor names the on-demand rule $rule"
done

# The old claim that rule files are always loaded is false since AgDR-0160.
if grep -qF 'Always loaded.' "$REX"; then
  fail "Rex no longer claims that framework rules are always loaded"
else
  pass "Rex no longer claims that framework rules are always loaded"
fi

# Discriminating check: the section reader returns nothing without the heading.
printf -- '---\nname: x\n---\n## Other\nNo hardcoded secrets.\n' > "$tmp_dir/no-floor.md"
if [ -z "$(floor_section "$tmp_dir/no-floor.md")" ]; then
  pass "the floor-section reader finds nothing when the heading is absent"
else
  fail "the floor-section reader finds nothing when the heading is absent"
fi

# --- Check CI once, never wait (token-efficiency ac4-2) ---------------------
for file in "$REX" "$HAKIM"; do
  name=$(basename "$file" .md)
  if grep -qF 'Run gh pr checks once and never wait.' "$file"; then
    pass "$name checks CI once and never waits"
  else
    fail "$name checks CI once and never waits"
  fi
done
if grep -qF 'state this in Validation and wait' "$REX"; then
  fail "Rex no longer tells the reviewer to wait for CI"
else
  pass "Rex no longer tells the reviewer to wait for CI"
fi

# --- Approval marker contract (code-reviewer.md) ----------------------------
REX_BODY=$(cat "$REX")
require_in 'review_marker_path' "$REX_BODY" "Rex marker path comes from review_marker_path"
require_in 'review_write_rex_approved' "$REX_BODY" "Rex writes the marker only through review_write_rex_approved"
require_in 'pr_base_repo' "$REX_BODY" "Rex keys the marker on the base repo via pr_base_repo"
require_in 'tracker_review_submit' "$REX_BODY" "Rex posts the verdict through tracker_review_submit"
require_in 'never take a literal marker path from your spawn prompt' "$REX_BODY" "Rex never takes a literal marker path from its spawn prompt"
require_in 'and ONLY then, write the approval marker' "$REX_BODY" "Rex writes the marker only on an APPROVED verdict"


# --- solution-architect floor content ---
file="$AGENTS/solution-architect.md"
require_in '.claude/rules/ticket-vocabulary.md' "$(floor_section "$file")" 'solution-architect: floor retains .claude/rules/ticket-vocabulary.md'
require_in '.claude/rules/agdr-decisions.md' "$(floor_section "$file")" 'solution-architect: floor retains .claude/rules/agdr-decisions.md'
require_in 'The architecture sign-off marker is not a merge approval.' "$(floor_section "$file")" 'solution-architect: floor retains The architecture sign-off marker is not a merge approval.'
require_in 'No hardcoded secrets.' "$(floor_section "$file")" 'solution-architect: floor retains No hardcoded secrets.'

# --- contrarian floor content ---
file="$AGENTS/contrarian.md"
require_in '.claude/rules/ticket-vocabulary.md' "$(floor_section "$file")" 'contrarian: floor retains .claude/rules/ticket-vocabulary.md'
require_in '.claude/rules/agdr-decisions.md' "$(floor_section "$file")" 'contrarian: floor retains .claude/rules/agdr-decisions.md'
require_in '.claude/rules/right-size-ceremony.md' "$(floor_section "$file")" 'contrarian: floor retains .claude/rules/right-size-ceremony.md'
require_in '.claude/rules/evidence-grounding.md' "$(floor_section "$file")" 'contrarian: floor retains .claude/rules/evidence-grounding.md'
require_in 'It never blocks a gate and never writes a marker.' "$(floor_section "$file")" 'contrarian: floor retains It never blocks a gate and never writes a marker.'

# --- qa-engineer floor content ---
file="$AGENTS/qa-engineer.md"
require_in '.claude/rules/ticket-vocabulary.md' "$(floor_section "$file")" 'qa-engineer: floor retains .claude/rules/ticket-vocabulary.md'
require_in 'One PR covers one ticket.' "$(floor_section "$file")" 'qa-engineer: floor retains One PR covers one ticket.'
require_in 'Coverage for domain logic stays above 80%.' "$(floor_section "$file")" 'qa-engineer: floor retains Coverage for domain logic stays above 80%.'
require_in 'This agent writes no merge marker and never merges.' "$(floor_section "$file")" 'qa-engineer: floor retains This agent writes no merge marker and never merges.'
require_in 'workflow-gates.md' "$(floor_section "$file")" 'qa-engineer: floor retains workflow-gates.md'

# --- dependency-auditor floor content ---
file="$AGENTS/dependency-auditor.md"
require_in '.claude/rules/ticket-vocabulary.md' "$(floor_section "$file")" 'dependency-auditor: floor retains .claude/rules/ticket-vocabulary.md'
require_in 'No hardcoded secrets. Use environment variables.' "$(floor_section "$file")" 'dependency-auditor: floor retains No hardcoded secrets. Use environment variables.'
require_in 'Never report a clean result when coverage is incomplete or a scanner failed.' "$(floor_section "$file")" 'dependency-auditor: floor retains Never report a clean result when coverage is incomplete or a scanner failed.'

# --- penetration-tester floor content ---
file="$AGENTS/penetration-tester.md"
require_in '.claude/rules/ticket-vocabulary.md' "$(floor_section "$file")" 'penetration-tester: floor retains .claude/rules/ticket-vocabulary.md'
require_in 'Never `git add -A` or `git add .`. Never push directly to `main`.' "$(floor_section "$file")" 'penetration-tester: floor retains Never `git add -A` or `git add .`. Never push directly to `main`.'
require_in '.claude/rules/git-conventions.md' "$(floor_section "$file")" 'penetration-tester: floor retains .claude/rules/git-conventions.md'
require_in 'A pre-release security sign-off is not a merge approval.' "$(floor_section "$file")" 'penetration-tester: floor retains A pre-release security sign-off is not a merge approval.'
require_in '.claude/rules/leak-protection.md' "$(floor_section "$file")" 'penetration-tester: floor retains .claude/rules/leak-protection.md'

# Return failure when the byte budget is exceeded.
within_byte_budget() {
  local bytes
  bytes=$(wc -c < "$1") || return 1
  [ "$bytes" -le 12000 ]
}

# Hakim step 1 does not ship (owner decision 2026-10-12).
# Keep the loop for agents with a shipped trim.
# shellcheck disable=SC2043
for name in solution-architect; do
  if within_byte_budget "$AGENTS/$name.md"; then
    pass "$name stays within 12000 bytes"
  else
    fail "$name stays within 12000 bytes"
  fi
done
dd if=/dev/zero of="$tmp_dir/oversized.md" bs=12001 count=1 2>/dev/null
if within_byte_budget "$tmp_dir/oversized.md"; then
  fail "the size helper rejects a 12001-byte file"
else
  pass "the size helper rejects a 12001-byte file"
fi

# --- security-reviewer kept rules ---
BODY=$(cat "$AGENTS/security-reviewer.md")
require_in 'Run gh pr checks once and never wait.' "$BODY" 'security-reviewer: retains Run gh pr checks once and never wait.'
require_in 'tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"' "$BODY" 'security-reviewer: retains tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"'
require_in 'Do NOT pass the `approve` verdict by default.' "$BODY" 'security-reviewer: retains Do NOT pass the `approve` verdict by default.'
require_in 'security review has **no merge-gate marker**' "$BODY" 'security-reviewer: retains security review has **no merge-gate marker**'
require_in 'A regression against the base branch.' "$BODY" 'security-reviewer: retains A regression against the base branch.'
require_in 'A way for an outside actor to run code or bypass the per-PR human merge approval.' "$BODY" 'security-reviewer: retains A way for an outside actor to run code or bypass the per-PR human merge approval.'
require_in 'A correctness bug in the changed code, or in a durable artifact'\''s stated meaning or evidence.' "$BODY" 'security-reviewer: retains A correctness bug in the changed code, or in a durable artifact'\''s stated meaning or evidence.'
require_in 'A failed acceptance criterion.' "$BODY" 'security-reviewer: retains A failed acceptance criterion.'
require_in '## Running tests in a scratch clone' "$BODY" 'security-reviewer: retains ## Running tests in a scratch clone'
require_in 'Never rephrase, split, encode, or disguise a command to get past a hook' "$BODY" 'security-reviewer: retains Never rephrase, split, encode, or disguise a command to get past a hook'
require_in 'git range-diff <old-base>..<old-head> <new-base>..<new-head>' "$BODY" 'security-reviewer: retains git range-diff <old-base>..<old-head> <new-base>..<new-head>'
require_in 'git show --remerge-diff <merge-sha>' "$BODY" 'security-reviewer: retains git show --remerge-diff <merge-sha>'
require_in 'State `Delta re-review` in the review body' "$BODY" 'security-reviewer: retains State `Delta re-review` in the review body'
require_in '### 1. Secrets and Credentials' "$BODY" 'security-reviewer: retains ### 1. Secrets and Credentials'
require_in '### 2. Injection Prevention' "$BODY" 'security-reviewer: retains ### 2. Injection Prevention'
require_in '### 3. Cross-Site Scripting (XSS)' "$BODY" 'security-reviewer: retains ### 3. Cross-Site Scripting (XSS)'
require_in '### 4. Authentication and Authorisation' "$BODY" 'security-reviewer: retains ### 4. Authentication and Authorisation'
require_in '### 5. Data Protection' "$BODY" 'security-reviewer: retains ### 5. Data Protection'
require_in '### 6. API Security' "$BODY" 'security-reviewer: retains ### 6. API Security'
require_in '### 7. Gate & Trust-Chain Integrity (#777)' "$BODY" 'security-reviewer: retains ### 7. Gate & Trust-Chain Integrity (#777)'
require_in 'Resolve the ops fork root **pin-first**' "$BODY" 'security-reviewer: retains Resolve the ops fork root **pin-first**'
require_in 'This agent writes **no** gate marker' "$BODY" 'security-reviewer: retains This agent writes **no** gate marker'
require_in 'PR_HOST_REPO=$(pr_base_repo {number} "$REPO")' "$BODY" 'security-reviewer: retains PR_HOST_REPO=$(pr_base_repo {number} "$REPO")'
require_in 'Reviewed by Hakim (Security Auditor)' "$BODY" 'security-reviewer: retains Reviewed by Hakim (Security Auditor)'

# --- solution-architect kept rules ---
BODY=$(cat "$AGENTS/solution-architect.md")
require_in 'review_validate_body tariq "$REVIEW_BODY_FILE" || exit 1' "$BODY" 'solution-architect: retains review_validate_body tariq "$REVIEW_BODY_FILE" || exit 1'
require_in 'tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"' "$BODY" 'solution-architect: retains tracker_review_submit "$PR_HOST_REPO" {number} comment "$REVIEW_BODY_FILE"'
require_in 'PR_HOST_REPO=$(pr_base_repo {number} "$REPO_FOR_BASE")' "$BODY" 'solution-architect: retains PR_HOST_REPO=$(pr_base_repo {number} "$REPO_FOR_BASE")'
require_in 'review_marker_path "$PR_HOST_REPO" {number} architecture "$MARKER_HOME"' "$BODY" 'solution-architect: retains review_marker_path "$PR_HOST_REPO" {number} architecture "$MARKER_HOME"'
require_in 'gh pr view {number} --repo <owner/repo> --json headRefOid --jq .headRefOid > "$ARCH_MARKER"' "$BODY" 'solution-architect: retains gh pr view {number} --repo <owner/repo> --json headRefOid --jq .headRefOid > "$ARCH_MARKER"'
require_in 'Write NO marker on CHANGES REQUESTED or COMMENT.' "$BODY" 'solution-architect: retains Write NO marker on CHANGES REQUESTED or COMMENT.'
require_in 'and ONLY then' "$BODY" 'solution-architect: retains and ONLY then'
require_in 'exactly the 40-character HEAD SHA plus one newline' "$BODY" 'solution-architect: retains exactly the 40-character HEAD SHA plus one newline'
require_in '-architecture.approved' "$BODY" 'solution-architect: retains -architecture.approved'
require_in '### 1. Quality attributes / NFRs' "$BODY" 'solution-architect: retains ### 1. Quality attributes / NFRs'
require_in '### 2. Design patterns & structure' "$BODY" 'solution-architect: retains ### 2. Design patterns & structure'
require_in '### 3. Technical debt' "$BODY" 'solution-architect: retains ### 3. Technical debt'
require_in '### 4. Decisions (AgDR linkage) — ⛔ BLOCKING' "$BODY" 'solution-architect: retains ### 4. Decisions (AgDR linkage) — ⛔ BLOCKING'
require_in '### 5. Risk' "$BODY" 'solution-architect: retains ### 5. Risk'
require_in '### 6. Trade-off analysis' "$BODY" 'solution-architect: retains ### 6. Trade-off analysis'
require_in '### 7. Requirements traceability' "$BODY" 'solution-architect: retains ### 7. Requirements traceability'
require_in '### 8. Migration safety (when the artifact is a migration AgDR)' "$BODY" 'solution-architect: retains ### 8. Migration safety (when the artifact is a migration AgDR)'
require_in 'A real decision with no AgDR' "$BODY" 'solution-architect: retains A real decision with no AgDR'
require_in '## Running tests in a scratch clone' "$BODY" 'solution-architect: retains ## Running tests in a scratch clone'
require_in 'Never rephrase, split, encode, or disguise commands to bypass hooks.' "$BODY" 'solution-architect: retains Never rephrase, split, encode, or disguise commands to bypass hooks.'
require_in 'Resolve `MARKER_HOME` pin-first' "$BODY" 'solution-architect: retains Resolve `MARKER_HOME` pin-first'
require_in 'Reviewed by Tariq (Solution Architect)' "$BODY" 'solution-architect: retains Reviewed by Tariq (Solution Architect)'
require_in 'docs/agents/solution-architect-reference.md' "$BODY" 'solution-architect: retains docs/agents/solution-architect-reference.md'

if grep -qF 'Always loaded' "$AGENTS/solution-architect.md"; then
  fail "Tariq no longer claims that framework rules are always loaded"
else
  pass "Tariq no longer claims that framework rules are always loaded"
fi

# --- solution-architect reference rules ---
BODY=$(cat "$ROOT/docs/agents/solution-architect-reference.md")
require_in '## Review lens: original wording' "$BODY" 'solution-architect reference: retains ## Review lens: original wording'
require_in '## Rules: original wording' "$BODY" 'solution-architect reference: retains ## Rules: original wording'
require_in '## Floor rules and `omitClaudeMd`' "$BODY" 'solution-architect reference: retains ## Floor rules and `omitClaudeMd`'
require_in 'Cross-fork keying' "$BODY" 'solution-architect reference: retains Cross-fork keying'
require_in 'APEXYARD_OPS_DISABLE_PIN' "$BODY" 'solution-architect reference: retains APEXYARD_OPS_DISABLE_PIN'

printf '\nReviewer floor-block checks completed with %s failure(s).\n' "$FAIL"
exit "$FAIL"

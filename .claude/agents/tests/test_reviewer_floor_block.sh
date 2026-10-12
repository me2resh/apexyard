#!/bin/bash
# Pins the omitClaudeMd setting and the floor-rules block of Rex, the
# check-CI-once line of Rex and Hakim, and the approval-marker contract in
# code-reviewer.md (me2resh/apexyard#1650). A trim of the Rex prompt must
# not drop these strings.
#
# Rex runs without CLAUDE.md, so its agent file must carry the always-on
# floor rules it enforces. Hakim and every other agent keep CLAUDE.md: the
# #1650 eval reverted omitClaudeMd for Hakim (see the eval report in
# docs/eval-agents/reports/), so no other agent may set it.
#
# The pinned strings hold literal backticks, so single quotes are intended.
# shellcheck disable=SC2016

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
AGENTS="$ROOT/.claude/agents"
REX="$AGENTS/code-reviewer.md"
HAKIM="$AGENTS/security-reviewer.md"
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

# Scope: Hakim and every other agent keep CLAUDE.md.
others=""
for file in "$AGENTS"/*.md; do
  [ "$file" = "$REX" ] && continue
  if frontmatter "$file" | grep -qE '^omitClaudeMd:'; then
    others="$others $(basename "$file")"
  fi
done
if [ -z "$others" ]; then
  pass "no agent other than Rex sets omitClaudeMd (Hakim included)"
else
  fail "no agent other than Rex sets omitClaudeMd (found:$others)"
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

# Hakim keeps CLAUDE.md, so it carries no floor block of its own.
if [ -z "$(floor_section "$HAKIM")" ]; then
  pass "Hakim has no floor-rules section (it keeps CLAUDE.md)"
else
  fail "Hakim has no floor-rules section (it keeps CLAUDE.md)"
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

printf '\nReviewer floor-block checks completed with %s failure(s).\n' "$FAIL"
exit "$FAIL"

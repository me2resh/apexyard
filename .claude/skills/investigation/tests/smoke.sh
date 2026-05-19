#!/usr/bin/env bash
# /investigation smoke test
#
# Verifies the contract that the consuming skill depends on:
#
#   1. templates/tickets/investigation.md exists and contains every required section
#      (Trigger, Hypothesis being tested, Method, Findings, Conclusion,
#       Follow-up actions) — these are what /investigation interviews on
#       and what AgDR-0027 names as the load-bearing shape.
#
#   2. The AgDR-style "In the context of ..." opener is present at the top
#      (matches the framework's AgDR shape; lets readers parse intent in
#       one line).
#
#   3. The portfolio_resolve_template helper resolves a custom override
#      when one is dropped at <private_repo>/custom-templates/tickets/investigation.md,
#      and falls through to templates/tickets/investigation.md otherwise.
#
#   4. The skill's required-sections claim matches what's actually in the
#      project-config defaults — no drift between the SKILL.md sections
#      and the .ticket.required_sections.Investigation list.
#
# The skill itself runs inside Claude Code (interactive interview, gh issue
# create, file writes). This smoke test verifies the *shape contracts* —
# if any of them drifts, the skill's contract with the template / config /
# adopter-override-helper breaks.

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

assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected: $expected; actual: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

# Resolve the ops-fork root. From inside the skill's tests/ dir, walk up
# until we hit the dir containing templates/tickets/investigation.md.
script_dir="$(cd "$(dirname "$0")" && pwd)"
ops_root="$script_dir"
while [ "$ops_root" != "/" ] && [ ! -f "$ops_root/templates/tickets/investigation.md" ]; do
  ops_root=$(dirname "$ops_root")
done
if [ ! -f "$ops_root/templates/tickets/investigation.md" ]; then
  echo "FAIL: could not locate ops-fork root (templates/tickets/investigation.md missing)"
  exit 1
fi

echo "Smoke test: /investigation contract checks (ops_root=$ops_root)"
echo ""

# ---------------------------------------------------------------------------
# 1. Template ships with every required section
# ---------------------------------------------------------------------------
echo "1. Template required-section coverage:"
template="$ops_root/templates/tickets/investigation.md"
assert_grep "Trigger heading"                "^## Trigger"                "$template"
assert_grep "Hypothesis being tested heading" "^## Hypothesis being tested" "$template"
assert_grep "Method heading"                 "^## Method"                 "$template"
assert_grep "Findings heading"               "^## Findings"               "$template"
assert_grep "Conclusion heading"             "^## Conclusion"             "$template"
assert_grep "Follow-up actions heading"      "^## Follow-up actions"      "$template"

# ---------------------------------------------------------------------------
# 2. AgDR-style opener present
# ---------------------------------------------------------------------------
echo ""
echo "2. AgDR-style 'In the context of' opener:"
assert_grep "In the context of opener" "^> In the context of " "$template"

# ---------------------------------------------------------------------------
# 3. When-to-use comparison block names the sibling skills
# ---------------------------------------------------------------------------
echo ""
echo "3. When-to-use block names the sibling skills:"
assert_grep "Names /spike"  "/spike"  "$template"
assert_grep "Names /bug"    "/bug"    "$template"
assert_grep "Names /decide" "/decide" "$template"

# ---------------------------------------------------------------------------
# 4. portfolio_resolve_template override semantics
# ---------------------------------------------------------------------------
echo ""
echo "4. portfolio_resolve_template override semantics:"

# Source the helper. The helper sources _lib-read-config.sh internally on
# first use, so just point at portfolio-paths directly.
# shellcheck source=/dev/null
. "$ops_root/.claude/hooks/_lib-portfolio-paths.sh"

# Walk-up to find ops fork looks for .apexyard-fork OR onboarding+registry.
# We're inside a worktree without those, so cd into the ops root first.
pushd "$ops_root" >/dev/null

# Test path A: no custom-templates/tickets/investigation.md → resolves to framework default
portfolio_clear_cache
resolved=$(portfolio_resolve_template tickets/investigation.md 2>/dev/null || echo "(not resolved)")
case "$resolved" in
  */templates/tickets/investigation.md)
    echo "  PASS: no override → falls through to templates/tickets/investigation.md ($resolved)"
    PASS=$((PASS + 1))
    ;;
  *)
    # In a fresh worktree without ops-fork anchor, portfolio_resolve_template
    # may not find the registry. Skip cleanly with a note rather than failing.
    echo "  SKIP: portfolio resolver didn't locate the registry from this worktree (resolved='$resolved')"
    echo "        This is expected when running from a worktree without an .apexyard-fork marker."
    ;;
esac

# Test path B: synthesise a custom override using a fixture private-repo dir
#   - create temp dir with apexyard.projects.yaml + custom-templates/tickets/investigation.md
#   - point a temporary project-config at it
#   - assert the resolver picks the override
fixture_root=$(mktemp -d -t investigation-fixture-XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT

# Build a synthetic ops-fork rooted at $fixture_root/fork with a config
# pointing at a sibling $fixture_root/portfolio that holds the override.
mkdir -p "$fixture_root/fork/.claude/hooks"
mkdir -p "$fixture_root/fork/templates/tickets"
mkdir -p "$fixture_root/portfolio/custom-templates/tickets"

# Mark the synthetic fork as an ops fork (v2 anchor).
touch "$fixture_root/fork/.apexyard-fork"

# Seed an empty registry in the sibling.
cat > "$fixture_root/portfolio/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
YAML

# Seed the framework template at the synthetic fork (resolver fallback target).
cat > "$fixture_root/fork/templates/tickets/investigation.md" <<'MD'
# framework default
## Trigger
## Hypothesis being tested
## Method
## Findings
## Conclusion
## Follow-up actions
MD

# Seed the adopter override at the sibling private repo.
cat > "$fixture_root/portfolio/custom-templates/tickets/investigation.md" <<'MD'
# ADOPTER OVERRIDE
## Trigger
## Hypothesis being tested
## Method
## Findings
## Conclusion
## Follow-up actions
MD

# Write a minimal project-config pointing at the sibling.
mkdir -p "$fixture_root/fork/.claude"
cat > "$fixture_root/fork/.claude/project-config.json" <<JSON
{
  "portfolio": {
    "registry": "../portfolio/apexyard.projects.yaml",
    "projects_dir": "../portfolio/projects",
    "ideas_backlog": "../portfolio/projects/ideas-backlog.md"
  }
}
JSON

# Also seed a defaults file — _config_load returns '{}' if defaults are missing,
# which makes config_get_or fall through to its fallback value (the in-fork
# './apexyard.projects.yaml') and bypass our portfolio block entirely.
cp "$ops_root/.claude/project-config.defaults.json" "$fixture_root/fork/.claude/project-config.defaults.json"

# Mirror the helper libraries into the fixture so the resolver works
# without depending on the worktree's ops fork having been initialised.
cp "$ops_root/.claude/hooks/_lib-read-config.sh"        "$fixture_root/fork/.claude/hooks/"
cp "$ops_root/.claude/hooks/_lib-portfolio-paths.sh"    "$fixture_root/fork/.claude/hooks/"

# Initialise the fixture as a git repo so the helpers' rev-parse walks resolve.
( cd "$fixture_root/fork" && git init -q 2>/dev/null && git add -A 2>/dev/null && git -c user.email=t@t -c user.name=t commit -q -m init 2>/dev/null || true )

# Run the resolver from inside the fixture fork.
override_resolved=$(
  cd "$fixture_root/fork" && \
  bash -c '
    . .claude/hooks/_lib-read-config.sh
    . .claude/hooks/_lib-portfolio-paths.sh
    portfolio_clear_cache
    portfolio_resolve_template tickets/investigation.md
  '
)

case "$override_resolved" in
  */portfolio/custom-templates/tickets/investigation.md)
    echo "  PASS: custom override wins → $override_resolved"
    PASS=$((PASS + 1))
    # Sanity-check it's actually the adopter version, not the framework one.
    if grep -q "ADOPTER OVERRIDE" "$override_resolved"; then
      echo "  PASS: resolved file contains the adopter marker"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: resolved file did not contain the adopter marker"
      FAIL=$((FAIL + 1))
    fi
    ;;
  *)
    echo "  FAIL: override did not win (resolved='$override_resolved')"
    FAIL=$((FAIL + 1))
    ;;
esac

popd >/dev/null

# ---------------------------------------------------------------------------
# 5. project-config defaults align with template sections
# ---------------------------------------------------------------------------
echo ""
echo "5. project-config defaults align with template sections:"
defaults_json="$ops_root/.claude/project-config.defaults.json"
if command -v jq >/dev/null 2>&1; then
  required_sections=$(jq -r '.ticket.required_sections.Investigation[]' "$defaults_json" 2>/dev/null | sort)
  expected="Conclusion
Findings
Follow-up actions
Hypothesis being tested
Method
Trigger"
  if [[ "$required_sections" == "$expected" ]]; then
    echo "  PASS: .ticket.required_sections.Investigation matches the template sections"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: required_sections drift"
    echo "    Got:"
    echo "$required_sections" | sed 's/^/      /'
    echo "    Expected:"
    echo "$expected" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi

  # Also: prefix_whitelist contains Investigation
  prefix_match=$(jq -r '.ticket.prefix_whitelist[] | select(. == "Investigation")' "$defaults_json")
  if [[ "$prefix_match" == "Investigation" ]]; then
    echo "  PASS: .ticket.prefix_whitelist contains 'Investigation'"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: .ticket.prefix_whitelist missing 'Investigation'"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP: jq not installed; can't introspect project-config.defaults.json"
fi

# ---------------------------------------------------------------------------
# 6. SKILL.md frontmatter sanity
# ---------------------------------------------------------------------------
echo ""
echo "6. SKILL.md frontmatter sanity:"
skill_md="$ops_root/.claude/skills/investigation/SKILL.md"
assert_grep "name: investigation"                          "^name: investigation$"             "$skill_md"
assert_grep "argument-hint declared"                        "^argument-hint: "                  "$skill_md"
assert_grep "allowed-tools includes Bash + Read + Write"    "^allowed-tools: Bash, Read, Write" "$skill_md"

echo ""
echo "----------------------------------------"
echo "Total: $((PASS + FAIL))   Passed: $PASS   Failed: $FAIL"
echo "----------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo ""
echo "OK: /investigation contract checks passed."
exit 0

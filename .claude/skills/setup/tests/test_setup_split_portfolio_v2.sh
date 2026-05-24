#!/bin/bash
# Sandbox-based test for the /setup split-portfolio v2 setup branch
# (`/setup` SKILL.md § Step 2b — "Walk through split-portfolio mode").
#
# `/setup` is a markdown skill, not a shell script, so this test does
# NOT drive the interactive prompts. Instead it runs the file-state
# steps the skill prescribes against a synthetic fork + sibling
# private-repo pair, then asserts the post-state matches the v2
# layout expectations from AgDR-0021 § B:
#
#   - All 7 v2 portfolio.* config keys land in .claude/project-config.json
#     (registry, projects_dir, ideas_backlog, onboarding, workspace_dir,
#      custom_skills_dir, custom_handbooks_dir)
#   - .apexyard-fork presence marker exists at the public-fork root with
#     the expected commented preamble (presence-only readers, AgDR-0021 § B)
#   - .gitignore has the 4 v2 paths excluded
#     (apexyard.projects.yaml, projects, onboarding.yaml, workspace)
#   - portfolio_validate succeeds on the post-state
#
# Companion to test_split_portfolio_v2_migration.sh (which tests the
# v1→v2 migration recipe inside /update step 8a). This one targets
# fresh /setup invocations on a brand-new fork.
#
# Exit 0 on all-pass, 1 on any fail.

set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
LIB_OPS="$ROOT/.claude/hooks/_lib-ops-root.sh"
LIB_PORT="$ROOT/.claude/hooks/_lib-portfolio-paths.sh"
LIB_CFG="$ROOT/.claude/hooks/_lib-read-config.sh"
DEFAULTS="$ROOT/.claude/project-config.defaults.json"

for f in "$LIB_OPS" "$LIB_PORT" "$LIB_CFG" "$DEFAULTS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing $f" >&2
    exit 1
  fi
done

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed; /setup v2 branch uses jq for config writes" >&2
  exit 0
fi

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { green "  ok   $1"; PASS=$((PASS+1)); }
mark_fail() {
  red "  FAIL $1: $2" >&2
  FAIL=$((FAIL+1))
  FAILED_CASES="$FAILED_CASES\n  - $1"
}

TMP_ROOT=$(mktemp -d)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT

# ---------------------------------------------------------------------------
# Fixture builder: a fresh public fork + sibling private repo with the
# v2 layout pre-built BUT the v2 marker and config block NOT YET written.
# The test then runs the SKILL.md Step 2b file-state actions and asserts
# the post-state.
# ---------------------------------------------------------------------------
build_pre_setup_v2() {
  local sb="$1"
  mkdir -p "$sb/public/.claude/hooks" "$sb/public/.claude"
  mkdir -p "$sb/private/projects" "$sb/private/workspace"

  # Public fork: framework files only — onboarding.yaml is still the
  # placeholder template, apexyard.projects.yaml NOT in the fork (lives
  # in the sibling private repo for v2 split-portfolio adopters).
  cat > "$sb/public/onboarding.yaml" <<'YAML'
company:
  name: "Your Company Name"
YAML

  cp "$LIB_OPS"  "$sb/public/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/public/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG"  "$sb/public/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/public/.claude/project-config.defaults.json"

  cat > "$sb/public/.gitignore" <<'IGNORE'
node_modules/
*.log
IGNORE

  # Init the public fork as a git repo so portfolio_root finds toplevel.
  (
    cd "$sb/public" \
      && git init -q \
      && git config user.email "t@t.t" \
      && git config user.name "t" \
      && git add -A \
      && git commit -q -m "fresh public fork (pre-v2-setup)"
  )

  # Sibling private repo: registry + projects/ + workspace/ + onboarding.yaml
  cat > "$sb/private/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
defaults:
  status: active
  ticket_prefix: GH
YAML
  cat > "$sb/private/projects/ideas-backlog.md" <<'MD'
# Ideas Backlog
MD
  cat > "$sb/private/onboarding.yaml" <<'YAML'
company:
  name: "Test Co"
  mission: "ship test infrastructure"
YAML
  mkdir -p "$sb/private/custom-skills" "$sb/private/custom-handbooks"

  # Seed an agent-routing.yaml.example in the public fork — SKILL.md
  # Step 5 copies this into the private repo as agent-routing.yaml.
  cat > "$sb/public/agent-routing.yaml.example" <<'YAML'
version: 1
# Adopter routing config — overrides framework default models per agent.
# Empty `agents: {}` block means zero overrides; framework defaults apply.
agents: {}
YAML
}

# ---------------------------------------------------------------------------
# Apply the SKILL.md Step 2b post-questionnaire file-state actions.
# Mirrors the bash blocks in `.claude/skills/setup/SKILL.md` § Step 2b
# (recommended v2 config-block mode).
# ---------------------------------------------------------------------------
apply_setup_v2() {
  local public="$1"
  local sibling_rel="$2"   # e.g. "../private"

  (
    cd "$public" || exit 99

    # 1. Append v2 gitignore lines.
    {
      echo ""
      echo "# Portfolio data lives in a separate private repo (split-portfolio v2)."
      echo "apexyard.projects.yaml"
      echo "projects"
      echo "onboarding.yaml"
      echo "workspace"
    } >> .gitignore

    # 2. Write the v2 config block (8 keys including agent_routing
    #    per #351 PR 3).
    cat > .claude/project-config.json <<JSON
{
  "portfolio": {
    "registry":             "$sibling_rel/apexyard.projects.yaml",
    "projects_dir":         "$sibling_rel/projects",
    "ideas_backlog":        "$sibling_rel/projects/ideas-backlog.md",
    "onboarding":           "$sibling_rel/onboarding.yaml",
    "workspace_dir":        "$sibling_rel/workspace",
    "custom_skills_dir":    "$sibling_rel/custom-skills",
    "custom_handbooks_dir": "$sibling_rel/custom-handbooks",
    "agent_routing":        "$sibling_rel/agent-routing.yaml"
  }
}
JSON

    # 3. Write the v2 presence marker.
    echo "# This file marks the directory as an ApexYard ops fork (split-portfolio v2)." > .apexyard-fork

    # 4. Seed agent-routing.yaml in the private repo by copying the
    #    framework example (#351 PR 3).
    if [ -f "agent-routing.yaml.example" ] && [ ! -f "$sibling_rel/agent-routing.yaml" ]; then
      cp agent-routing.yaml.example "$sibling_rel/agent-routing.yaml"
    fi
  )
}

# ---------------------------------------------------------------------------
# Case 1: full v2 setup branch — assert all 7 keys + marker + gitignore
# ---------------------------------------------------------------------------
echo "== Case 1: /setup v2 setup branch writes v2 layout"
SB="$TMP_ROOT/case1"
build_pre_setup_v2 "$SB"
apply_setup_v2 "$SB/public" "../private"

# Assertion 1: all 8 v2 portfolio keys exist in project-config.json
PCONFIG="$SB/public/.claude/project-config.json"
EXPECTED_KEYS=(registry projects_dir ideas_backlog onboarding workspace_dir custom_skills_dir custom_handbooks_dir agent_routing)
all_keys_present=1
for k in "${EXPECTED_KEYS[@]}"; do
  v=$(jq -r ".portfolio.$k // empty" "$PCONFIG")
  if [ -z "$v" ]; then
    mark_fail "v2 key $k present" "key missing from project-config.json"
    all_keys_present=0
  fi
done
if [ "$all_keys_present" -eq 1 ]; then
  mark_pass "all 8 v2 portfolio.* keys present in project-config.json (includes agent_routing per #351 PR 3)"
fi

# Assertion 1b: agent-routing.yaml was seeded into the private repo
PRIVATE_ROUTING="$SB/private/agent-routing.yaml"
if [ -f "$PRIVATE_ROUTING" ] && grep -q '^agents:' "$PRIVATE_ROUTING"; then
  mark_pass "agent-routing.yaml seeded in private repo from framework example (#351 PR 3)"
elif [ -f "$PRIVATE_ROUTING" ]; then
  mark_fail "agent-routing.yaml content" "file exists but doesn't carry the 'agents:' key — example seed appears malformed"
else
  mark_fail "agent-routing.yaml present" "expected at $PRIVATE_ROUTING (Step 5 should copy from example)"
fi

# Assertion 2: .apexyard-fork marker exists with expected commented preamble
MARKER="$SB/public/.apexyard-fork"
if [ -f "$MARKER" ]; then
  mark_pass ".apexyard-fork marker present at fork root"
else
  mark_fail "marker present" "$MARKER missing"
fi
if [ -f "$MARKER" ] && head -n 1 "$MARKER" | grep -q "ApexYard ops fork (split-portfolio v2)"; then
  mark_pass ".apexyard-fork carries the expected commented preamble"
else
  mark_fail "marker content" "preamble line missing or wrong"
fi

# Assertion 3: .gitignore has 4 v2 paths excluded
GI="$SB/public/.gitignore"
for path in apexyard.projects.yaml projects onboarding.yaml workspace; do
  if grep -qxF "$path" "$GI"; then
    mark_pass ".gitignore excludes '$path'"
  else
    mark_fail "gitignore exclude $path" "missing from $GI"
  fi
done

# Assertion 4: portfolio_validate succeeds on the post-state
(
  cd "$SB/public" || exit 1
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  if portfolio_validate >/dev/null 2>&1; then
    exit 0
  else
    err=$(portfolio_validate 2>&1)
    echo "validate failed: $err" >&2
    exit 1
  fi
)
if [ "$?" -eq 0 ]; then
  mark_pass "portfolio_validate happy on post-setup v2 layout"
else
  mark_fail "portfolio_validate" "see error above"
fi

# Assertion 5: portfolio_is_v2 returns 0 (true) on the post-state
(
  cd "$SB/public" || exit 1
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  if portfolio_is_v2; then
    exit 0
  else
    exit 1
  fi
)
if [ "$?" -eq 0 ]; then
  mark_pass "portfolio_is_v2 detects the post-setup state as v2"
else
  mark_fail "portfolio_is_v2 detection" "expected v2 but got v1/single-fork"
fi

# Assertion 6: ops-root walk finds the public fork via .apexyard-fork
# (proves the v2 layout works even though onboarding+registry are not in
#  the public fork)
(
  # shellcheck source=/dev/null
  . "$LIB_OPS"
  out=$(cd "$SB/public" && resolve_ops_root)
  [ "$out" = "$SB/public" ] || { echo "ops_root expected $SB/public got $out" >&2; exit 1; }
  exit 0
)
if [ "$?" -eq 0 ]; then
  mark_pass "resolve_ops_root finds public fork via .apexyard-fork marker"
else
  mark_fail "resolve_ops_root" "see error above"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_setup_split_portfolio_v2.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:%b\n' "$FAILED_CASES"
  exit 1
fi
exit 0

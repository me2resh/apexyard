#!/bin/bash
# Sandbox-based test for the /setup single-fork branch
# (`/setup` SKILL.md § Step 6 — "Write onboarding.yaml + the .apexyard-fork marker"
#  in single-fork mode).
#
# Single-fork setup is the simpler path: edit onboarding.yaml in place to
# replace placeholder values, write the .apexyard-fork marker, and do
# NOT write a portfolio: config block (single-fork uses the in-fork
# defaults for all five resolver paths).
#
# This test simulates a fresh fork where the operator has just answered
# the Step 2 questions ("describe your stack"), then applies the
# Step 6 file-state actions, then asserts:
#
#   - onboarding.yaml has the company.name placeholder replaced
#   - .apexyard-fork marker present (idempotent — written even in
#     single-fork mode, per AgDR-0021 § B + SKILL.md Step 6)
#   - .claude/project-config.json is NOT written (single-fork mode
#     uses defaults entirely)
#   - portfolio_validate succeeds against the in-fork defaults
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
# Fixture: a fresh single-fork with placeholder onboarding.yaml + minimal
# in-fork registry + projects/ dir. Mirrors the layout an adopter who
# JUST forked apexyard would have before invoking /setup.
# ---------------------------------------------------------------------------
build_pre_setup_single_fork() {
  local sb="$1"
  mkdir -p "$sb/.claude/hooks" "$sb/projects"

  # Placeholder onboarding.yaml (matches the framework template detector
  # in SKILL.md Step 1: `grep -q '"Your Company Name"' onboarding.yaml`).
  cat > "$sb/onboarding.yaml" <<'YAML'
# ApexYard Onboarding
company:
  name: "Your Company Name"
  mission: "What you're building and why"
YAML

  # Minimal in-fork registry.
  cat > "$sb/apexyard.projects.yaml" <<'YAML'
version: 1
projects: []
YAML

  cat > "$sb/projects/ideas-backlog.md" <<'MD'
# Ideas Backlog
MD

  cp "$LIB_OPS"  "$sb/.claude/hooks/_lib-ops-root.sh"
  cp "$LIB_PORT" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  cp "$LIB_CFG"  "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"

  (
    cd "$sb" \
      && git init -q \
      && git config user.email "t@t.t" \
      && git config user.name "t" \
      && git add -A \
      && git commit -q -m "fresh single-fork (pre-setup)"
  )
}

# ---------------------------------------------------------------------------
# Apply the SKILL.md Step 6 single-fork actions:
#   - Replace the company.name placeholder with a real value
#   - Write the .apexyard-fork presence marker
#   - Do NOT write a portfolio: config block
# ---------------------------------------------------------------------------
apply_setup_single_fork() {
  local fork="$1"
  local company_name="$2"

  (
    cd "$fork" || exit 99
    # Use sed -i.bak for macOS / GNU compat.
    sed -i.bak "s/\"Your Company Name\"/\"$company_name\"/" onboarding.yaml
    rm -f onboarding.yaml.bak

    if [ ! -f .apexyard-fork ]; then
      echo "# This file marks the directory as an ApexYard ops fork." > .apexyard-fork
    fi
  )
}

# ---------------------------------------------------------------------------
# Case 1: single-fork setup writes placeholder replacement + marker only
# ---------------------------------------------------------------------------
echo "== Case 1: /setup single-fork branch fills placeholders + writes marker"
SB="$TMP_ROOT/case1"
build_pre_setup_single_fork "$SB"

# Pre-state sanity: placeholder is present
if grep -q '"Your Company Name"' "$SB/onboarding.yaml"; then
  mark_pass "pre-state: company.name placeholder detected"
else
  mark_fail "pre-state placeholder" "expected placeholder in onboarding.yaml"
  exit 1
fi

apply_setup_single_fork "$SB" "ApexScript"

# Assertion 1: onboarding.yaml has real company name, placeholder gone
if grep -q '"ApexScript"' "$SB/onboarding.yaml"; then
  mark_pass "onboarding.yaml has real company name written in"
else
  mark_fail "onboarding company name" "ApexScript not found in onboarding.yaml"
fi
if grep -q '"Your Company Name"' "$SB/onboarding.yaml"; then
  mark_fail "placeholder cleared" "placeholder still present after setup"
else
  mark_pass "placeholder cleared from onboarding.yaml"
fi

# Assertion 2: .apexyard-fork marker present (single-fork mode also gets
# the marker per SKILL.md Step 6 + AgDR-0021 § B)
if [ -f "$SB/.apexyard-fork" ]; then
  mark_pass ".apexyard-fork marker present even in single-fork mode"
else
  mark_fail "marker present" ".apexyard-fork missing"
fi

# Assertion 3: NO portfolio: config block — single-fork mode relies on defaults
if [ -f "$SB/.claude/project-config.json" ]; then
  # If it exists, it must NOT have a .portfolio key
  if command -v jq >/dev/null 2>&1; then
    has_portfolio=$(jq -r 'has("portfolio")' "$SB/.claude/project-config.json" 2>/dev/null)
    if [ "$has_portfolio" = "true" ]; then
      mark_fail "no portfolio block in single-fork" "project-config.json has a portfolio: key"
    else
      mark_pass "no portfolio: block written in single-fork mode (defaults apply)"
    fi
  else
    mark_pass "no portfolio: block (jq absent, presence-only check)"
  fi
else
  mark_pass "no .claude/project-config.json written in single-fork mode"
fi

# Assertion 4: portfolio_validate succeeds — in-fork defaults resolve correctly
(
  cd "$SB" || exit 1
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
  mark_pass "portfolio_validate happy on single-fork post-setup state"
else
  mark_fail "portfolio_validate single-fork" "see error above"
fi

# Assertion 5: registry is the in-fork file (resolved through defaults)
(
  cd "$SB" || exit 1
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-read-config.sh
  # shellcheck source=/dev/null
  . .claude/hooks/_lib-portfolio-paths.sh
  portfolio_clear_cache
  reg=$(portfolio_registry)
  [ "$reg" = "$SB/apexyard.projects.yaml" ] || {
    echo "expected $SB/apexyard.projects.yaml, got $reg" >&2
    exit 1
  }
  exit 0
)
if [ "$?" -eq 0 ]; then
  mark_pass "portfolio_registry resolves to in-fork apexyard.projects.yaml"
else
  mark_fail "registry resolution" "see error above"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_setup_single_fork.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:%b\n' "$FAILED_CASES"
  exit 1
fi
exit 0

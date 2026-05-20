#!/bin/bash
# Sandbox-based test for the /setup --reset flag
# (`/setup` SKILL.md § Step 1 — "Check current state" + `--reset` case).
#
# The --reset flag clears onboarding.yaml back to the template defaults
# so the operator can re-run /setup from a clean slate. This test:
#
#   1. Builds a sandbox fork with a CUSTOMISED onboarding.yaml (real
#      company name, placeholder gone) — i.e. /setup has already run
#      against this fork at some point.
#   2. Applies the --reset semantics (overwrite onboarding.yaml with the
#      framework template defaults).
#   3. Asserts the post-state matches the original template (placeholder
#      back in place, ready for a fresh /setup run).
#
# Out of scope: testing the --reset interactive prompt branch in Step 1
# (operator-interactive, not file-state). The file-state outcome IS what
# matters for regression coverage.
#
# Exit 0 on all-pass, 1 on any fail.

set -u

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
TEMPLATE_SRC="$ROOT/onboarding.yaml"

if [ ! -f "$TEMPLATE_SRC" ]; then
  echo "FAIL: framework template $TEMPLATE_SRC not found" >&2
  exit 1
fi

# Sanity check — the live framework template still ships the expected
# placeholder. If this ever changes, this test (and the SKILL.md
# detection grep) must change too.
if ! grep -q '"Your Company Name"' "$TEMPLATE_SRC"; then
  echo "FAIL: framework onboarding.yaml lacks the 'Your Company Name' placeholder — template detection grep in SKILL.md Step 1 is broken" >&2
  exit 1
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
# Fixture: a fork where /setup has ALREADY run — onboarding.yaml carries
# a real company name + non-placeholder values.
# ---------------------------------------------------------------------------
build_post_setup_fork() {
  local sb="$1"
  mkdir -p "$sb"

  cat > "$sb/onboarding.yaml" <<'YAML'
# ApexYard Onboarding (post-setup state)
company:
  name: "ApexScript"
  mission: "Property management SaaS"
  values:
    - "Quality over speed"
YAML
}

# ---------------------------------------------------------------------------
# Apply the --reset semantics: overwrite onboarding.yaml with the
# framework template defaults (read from $TEMPLATE_SRC — the same file
# `/setup` copies from upstream).
# ---------------------------------------------------------------------------
apply_setup_reset() {
  local fork="$1"
  cp "$TEMPLATE_SRC" "$fork/onboarding.yaml"
}

# ---------------------------------------------------------------------------
# Case 1: --reset on a configured fork restores the template defaults
# ---------------------------------------------------------------------------
echo "== Case 1: /setup --reset clears onboarding.yaml back to template defaults"
SB="$TMP_ROOT/case1"
build_post_setup_fork "$SB"

# Pre-state sanity: customised content present, placeholder absent
if grep -q '"ApexScript"' "$SB/onboarding.yaml"; then
  mark_pass "pre-state: configured fork has real company name"
else
  mark_fail "pre-state customised" "expected ApexScript in onboarding.yaml"
  exit 1
fi
if grep -q '"Your Company Name"' "$SB/onboarding.yaml"; then
  mark_fail "pre-state placeholder absent" "placeholder unexpectedly present pre-reset"
  exit 1
else
  mark_pass "pre-state: placeholder absent (real config in place)"
fi

apply_setup_reset "$SB"

# Assertion 1: customised values are gone after reset
if grep -q '"ApexScript"' "$SB/onboarding.yaml"; then
  mark_fail "customised values cleared" "ApexScript still present after --reset"
else
  mark_pass "customised company name cleared from onboarding.yaml"
fi

# Assertion 2: placeholder is back — the SKILL.md Step 1 detection grep
# (`grep -q '"Your Company Name"'`) re-fires, treating the fork as fresh.
if grep -q '"Your Company Name"' "$SB/onboarding.yaml"; then
  mark_pass "placeholder restored — SKILL.md Step 1 detection grep will re-fire"
else
  mark_fail "placeholder restored" "expected 'Your Company Name' back in onboarding.yaml"
fi

# Assertion 3: post-reset onboarding.yaml content matches the framework template
if diff -q "$TEMPLATE_SRC" "$SB/onboarding.yaml" >/dev/null 2>&1; then
  mark_pass "post-reset onboarding.yaml matches the framework template byte-for-byte"
else
  mark_fail "template match" "post-reset content differs from $TEMPLATE_SRC"
fi

# ---------------------------------------------------------------------------
# Case 2: --reset is idempotent — running it twice is a no-op
# ---------------------------------------------------------------------------
echo "== Case 2: --reset is idempotent (re-running yields same state)"
SHA_BEFORE=$(shasum "$SB/onboarding.yaml" | awk '{print $1}')
apply_setup_reset "$SB"
SHA_AFTER=$(shasum "$SB/onboarding.yaml" | awk '{print $1}')
if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
  mark_pass "second --reset is a no-op (sha unchanged)"
else
  mark_fail "idempotent reset" "sha changed: $SHA_BEFORE → $SHA_AFTER"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "===== test_setup_reset.sh ====="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:%b\n' "$FAILED_CASES"
  exit 1
fi
exit 0

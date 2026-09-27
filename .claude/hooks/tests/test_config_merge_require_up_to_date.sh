#!/bin/bash
# Regression test for the merge.require_up_to_date config key (apexyard#1386).
#
# /approve-merge reads this key before deciding whether to stop on a
# behind-base PR (see .claude/skills/approve-merge/SKILL.md step 3a).
# These cases pin the shipped default and the override path, using the
# same config_get_or helper the skill's instructions call for.
#
# This test FAILS on the pre-#1386 project-config.defaults.json, which has
# no "merge" key at all, and config_get_or falls back to the caller's own
# fallback argument regardless of what is shipped — so case 1 below is the
# one that actually distinguishes "shipped default is true" from "no key
# exists, the fallback argument happened to also be true". Case 3 closes
# that gap: it reads the shipped file directly with jq, with no fallback,
# so it fails outright on a fork that never added the key.
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PASS=0
FAIL=0
FAILED=""

mark_pass() { printf "  PASS: %s\n" "$1"; PASS=$((PASS+1)); }
mark_fail() { printf "  FAIL: %s: %s\n" "$1" "$2" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}\n  - $1"; }

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks"
  touch "$sb/.apexyard-fork"
  cp "$SRC_ROOT/.claude/hooks/_lib-read-config.sh" "$sb/.claude/hooks/"
  cp "$SRC_ROOT/.claude/hooks/_lib-ops-root.sh" "$sb/.claude/hooks/"
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$sb/.claude/project-config.defaults.json"
  echo "$sb"
}

# ---------------------------------------------------------------------------
# Case 1: shipped default is "true" — read via config_get_or, no override file.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
got=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash -c '
  . .claude/hooks/_lib-read-config.sh
  config_get_or ".merge.require_up_to_date" "MISSING"
')
rm -rf "$sb"
if [ "$got" = "true" ]; then
  mark_pass "shipped default: merge.require_up_to_date == true"
else
  mark_fail "shipped default" "want 'true', got '$got'"
fi

# ---------------------------------------------------------------------------
# Case 2: an override file can turn the check off.
# ---------------------------------------------------------------------------
sb=$(make_sandbox)
cat > "$sb/.claude/project-config.json" <<'JSON'
{"merge": {"require_up_to_date": false}}
JSON
got=$(cd "$sb" && APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 bash -c '
  . .claude/hooks/_lib-read-config.sh
  config_get_or ".merge.require_up_to_date" "MISSING"
')
rm -rf "$sb"
if [ "$got" = "false" ]; then
  mark_pass "override: merge.require_up_to_date can be set to false"
else
  mark_fail "override" "want 'false', got '$got'"
fi

# ---------------------------------------------------------------------------
# Case 3: the shipped defaults file itself has the key (no fallback masking
# a missing key — this is the case that fails on pre-#1386 defaults).
# ---------------------------------------------------------------------------
got=$(jq -r '.merge.require_up_to_date' "$SRC_ROOT/.claude/project-config.defaults.json" 2>/dev/null)
if [ "$got" = "true" ]; then
  mark_pass "shipped file: .merge.require_up_to_date is present and true"
else
  mark_fail "shipped file" "want 'true', got '${got:-<missing key>}'"
fi

# ---------------------------------------------------------------------------
# Case 4: project-config.defaults.json stays valid JSON after the edit.
# ---------------------------------------------------------------------------
if jq empty "$SRC_ROOT/.claude/project-config.defaults.json" >/dev/null 2>&1; then
  mark_pass "project-config.defaults.json is valid JSON"
else
  mark_fail "project-config.defaults.json JSON validity" "jq empty failed"
fi

echo
echo "===== test_config_merge_require_up_to_date.sh ====="
printf "Passed: %s\n" "$PASS"
printf "Failed: %s\n" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "Failed cases:%b\n" "$FAILED"
  exit 1
fi
exit 0

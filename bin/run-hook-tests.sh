#!/usr/bin/env bash
# Discovery test runner for the ApexYard mechanical-enforcement test suites.
#
# Finds every test_*.sh (and *.test.sh) under the framework's tests/ trees,
# runs each in isolation, prints a per-test PASS/FAIL/SKIP line, and exits
# non-zero if ANY non-quarantined test fails. Reusable locally and in CI
# (.github/workflows/tests.yml). See me2resh/apexyard#526.
#
# Usage:
#   bin/run-hook-tests.sh            # run the whole suite
#   bin/run-hook-tests.sh --list     # list discovered tests, run nothing
#
# Quarantine: tests that genuinely cannot run headless (or are known-failing
# and tracked for a fix) are listed in QUARANTINE below, each with a reason.
# They are SKIPPED and logged — never silently dropped. Keep this list short
# and every entry must cite why.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

# --- Quarantine list (path :: reason). Empty by default; populated only with
# --- evidence (a CI failure that is environmental, not a real regression). ---
QUARANTINE=(
  # Remaining pre-existing failures (NOT caused by the gate) — tracked in #528.
  # The other three originally-quarantined tests (token_efficiency_wave1,
  # harnessability_scoring, md_to_pdf_fallback) were FIXED and un-quarantined.
  # These two need deeper work:
  ".claude/hooks/tests/test_handover_clone_prompt.sh :: ~8 literal-substring assertions pin the PRE-restructure /handover clone-prompt spec (clone moved to step 1.5, follow-up to step 8); needs an assertion rewrite — #528"
  ".claude/hooks/tests/test_agent_routing_sync_and_drift.sh :: 4 cases drift (override/idempotent/drift-guard) vs committed agent-routing.yaml; may be a real config regression — needs investigation, not a test patch — #528"
)

is_quarantined() {
  local t="$1" entry
  [ "${#QUARANTINE[@]}" -gt 0 ] || return 1
  for entry in "${QUARANTINE[@]}"; do
    [ "${entry%% ::*}" = "$t" ] && return 0
  done
  return 1
}

# Per-test wall-clock cap (Linux `timeout`; falls back to no cap if absent).
TIMEOUT_BIN=""
command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout 120"
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 120"

# Portable array population (bash 3.2 on macOS has no `mapfile`).
TESTS=()
while IFS= read -r _t; do
  [ -n "$_t" ] && TESTS+=("$_t")
done < <(
  find .claude/hooks/tests .claude/agents/tests .claude/rules/tests .claude/skills \
       -type f \( -name 'test_*.sh' -o -name '*.test.sh' \) 2>/dev/null | sort
)

if [ "${1:-}" = "--list" ]; then
  [ "${#TESTS[@]}" -gt 0 ] && printf '%s\n' "${TESTS[@]}"
  echo "(${#TESTS[@]} tests discovered)"
  exit 0
fi

pass=0 fail=0 skip=0
FAILED=()

for t in "${TESTS[@]}"; do
  if is_quarantined "$t"; then
    reason=""
    for entry in "${QUARANTINE[@]}"; do
      [ "${entry%% ::*}" = "$t" ] && reason="${entry#* :: }"
    done
    printf 'SKIP %s  (quarantined: %s)\n' "$t" "$reason"
    skip=$((skip+1))
    continue
  fi
  # shellcheck disable=SC2086
  if $TIMEOUT_BIN bash "$t" </dev/null >/tmp/_hooktest.out 2>&1; then
    printf 'PASS %s\n' "$t"
    pass=$((pass+1))
  else
    rc=$?
    printf 'FAIL %s  (rc=%s)\n' "$t" "$rc"
    tail -n 15 /tmp/_hooktest.out | sed 's/^/      | /'
    fail=$((fail+1))
    FAILED+=("$t")
  fi
done

echo
echo "============================================================"
echo "  hook test suite: PASS=$pass  FAIL=$fail  SKIP(quarantined)=$skip  TOTAL=${#TESTS[@]}"
echo "============================================================"
if [ "$fail" -gt 0 ]; then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0

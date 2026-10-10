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
#   bin/run-hook-tests.sh --shard 1/4 # run one round-robin shard
#   HOOK_TEST_SHARD=1 HOOK_TEST_SHARDS=4 bin/run-hook-tests.sh
#
# Quarantine: tests that genuinely cannot run headless (or are known-failing
# and tracked for a fix) are listed in QUARANTINE below, each with a reason.
# They are SKIPPED and logged — never silently dropped. Keep this list short
# and every entry must cite why.

set -uo pipefail

LIST=0
SHARD=${HOOK_TEST_SHARD-}
SHARDS=${HOOK_TEST_SHARDS-}
shard_error() {
  echo "Invalid shard: use --shard I/N or HOOK_TEST_SHARD=I HOOK_TEST_SHARDS=N (1 <= I <= N)." >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --list) LIST=1; shift ;;
    --shard)
      [ "$#" -ge 2 ] || shard_error
      case "$2" in */*) ;; *) shard_error ;; esac
      SHARD=${2%%/*}
      SHARDS=${2#*/}
      shift 2
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$SHARD$SHARDS" ] || [ "${HOOK_TEST_SHARD+x}${HOOK_TEST_SHARDS+x}" != "" ]; then
  case "$SHARD:$SHARDS" in *[!0-9:]*|:*|*:) shard_error ;; esac
  # Strip leading zeroes before arithmetic (bash otherwise interprets octal).
  SHARD=$(printf '%s' "$SHARD" | sed 's/^0*//')
  SHARDS=$(printf '%s' "$SHARDS" | sed 's/^0*//')
  [ -n "$SHARD" ] && [ -n "$SHARDS" ] || shard_error
  # Keep arithmetic within the signed integer range on supported hosts.
  [ "${#SHARD}" -le 18 ] && [ "${#SHARDS}" -le 18 ] || shard_error
  [ "$SHARD" -le "$SHARDS" ] || shard_error
else
  SHARD=1
  SHARDS=1
fi
START_SECONDS=$SECONDS

# Test isolation (#528 + #1549): many hooks resolve their ops-root via
# _lib-ops-root.sh, which inside a live Claude Code session honours the session
# pin ($APEXYARD_OPS_PIN_DIR/ops-root-$CLAUDE_CODE_SESSION_ID) and points at the
# REAL fork — so a sandbox-based test would escape onto the real repo (wrong
# results, and for writing hooks like apply-agent-routing / link-custom-skills,
# real-file mutation). Disable the pin for the whole suite so every test
# resolves by walk-up to its own sandbox. No-op in headless CI (no pin). Tests
# that specifically exercise the pin (test_resolve_ops_root_pin.sh) set/unset
# this per-case, so the suite-level default doesn't interfere.
#
# #1549: also drop an inherited CLAUDE_CODE_SESSION_ID and redirect
# APEXYARD_OPS_PIN_DIR to a fresh temp directory. Without that, pin-ops-root.sh
# and resolve-cache writers overwrite the operator's real
# ~/.claude/apexyard/ops-root-<session> and resolve-cache-<session>-* files.
export APEXYARD_OPS_DISABLE_PIN=1

# Same isolation rationale, for the session-scoped resolution cache added in
# me2resh/apexyard#1013 (AgDR-0120): _lib-resolution-cache.sh keys its cache
# files on $CLAUDE_CODE_SESSION_ID, which (when this suite runs inside a live
# Claude Code session) would otherwise be the REAL session id -- a
# sandbox-based test would read stale fixtures back into the real session's
# cache, or pollute it with sandbox values. Tests that specifically exercise
# the cache (test_resolution_cache.sh) set/unset this per-case.
export APEXYARD_DISABLE_RESOLUTION_CACHE=1

unset CLAUDE_CODE_SESSION_ID
SUITE_PIN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-hook-suite-pins.XXXXXX") || exit 1
# Share one pin dir with suites that source _test-session-isolation.sh so a
# full run does not leave ~N mktemp directories behind; remove on EXIT.
export _APEXYARD_TEST_PIN_DIR="$SUITE_PIN_DIR"
export APEXYARD_OPS_PIN_DIR="$SUITE_PIN_DIR"
OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-hook-suite-output.XXXXXX") || {
  rm -rf "$SUITE_PIN_DIR"
  exit 1
}
trap 'rm -rf "$SUITE_PIN_DIR" "$OUTPUT_DIR"' EXIT

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

# --- Quarantine list (path :: reason). Empty by default; populated only with
# --- evidence (a CI failure that is environmental, not a real regression). ---
QUARANTINE=(
  # These tests require tools or host features that the CI job does not
  # provide. They remain visible as explicit SKIP entries and do not hide
  # skips from other suites.
  ".claude/hooks/tests/test_lib_self_location_cwd_anchor.sh :: requires a non-standard working-directory layout"
  ".claude/hooks/tests/test_portfolio_paths_case_insensitive_fs.sh :: requires a case-insensitive filesystem"
  ".claude/hooks/tests/test_pre_push_gate_case_insensitive_fs.sh :: requires a case-insensitive filesystem"
  ".claude/hooks/tests/test_tracker_zsh_self_location.sh :: requires zsh"
  ".claude/skills/pdf/tests/test_md_to_pdf_fallback.sh :: requires opt-in PDF end-to-end dependencies"
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
  find .claude/hooks/tests .claude/agents/tests .claude/skills \
       -type f \( -name 'test_*.sh' -o -name '*.test.sh' \) 2>/dev/null | LC_ALL=C sort
)

SELECTED=()
for ((k=0; k<${#TESTS[@]}; k++)); do
  if [ "$((k % SHARDS))" -eq "$((SHARD - 1))" ]; then
    SELECTED+=("${TESTS[$k]}")
  fi
done
# bash 3.2 treats an empty "${arr[@]}" as unbound under set -u.
TESTS=(${SELECTED[@]+"${SELECTED[@]}"})

if [ "$LIST" -eq 1 ]; then
  [ "${#TESTS[@]}" -gt 0 ] && printf '%s\n' "${TESTS[@]}"
  echo "(${#TESTS[@]} tests discovered)"
  exit 0
fi

printf 'hook tests: shard %s/%s, %s tests\n' "$SHARD" "$SHARDS" "${#TESTS[@]}"

pass=0 fail=0 skip=0
FAILED=()

test_index=0
for t in ${TESTS[@]+"${TESTS[@]}"}; do
  output="$OUTPUT_DIR/$test_index.out"
  test_index=$((test_index+1))
  if is_quarantined "$t"; then
    reason=""
    for entry in "${QUARANTINE[@]}"; do
      [ "${entry%% ::*}" = "$t" ] && reason="${entry#* :: }"
    done
    printf 'SKIP %s  (quarantined: %s)\n' "$t" "$reason"
    skip=$((skip+1))
    continue
  fi
  # Force isolation even when a suite forgets to source
  # _test-session-isolation.sh (me2resh/apexyard#1549).
  # Pass _APEXYARD_TEST_PIN_DIR so the helper reuses SUITE_PIN_DIR.
  # shellcheck disable=SC2086
  if env -u CLAUDE_CODE_SESSION_ID \
      APEXYARD_OPS_DISABLE_PIN=1 \
      APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
      APEXYARD_OPS_PIN_DIR="$SUITE_PIN_DIR" \
      _APEXYARD_TEST_PIN_DIR="$SUITE_PIN_DIR" \
      $TIMEOUT_BIN bash "$t" </dev/null >"$output" 2>&1; then
    if grep -q '^SKIP' "$output"; then
      printf '  diagnostics from %s:\n' "$t"
      grep '^SKIP' "$output" | sed 's/^/    /'
      skip=$((skip+1))
      printf 'FAIL %s  (suite reported a skipped case)\n' "$t"
      fail=$((fail+1))
      FAILED+=("$t")
    else
      printf 'PASS %s\n' "$t"
      pass=$((pass+1))
    fi
  else
    rc=$?
    printf 'FAIL %s  (rc=%s)\n' "$t" "$rc"
    tail -n 15 "$output" | sed 's/^/      | /'
    fail=$((fail+1))
    FAILED+=("$t")
  fi
done

echo
echo "============================================================"
echo "  hook test suite: PASS=$pass  FAIL=$fail  SKIP(quarantined)=$skip  TOTAL=${#TESTS[@]}"
echo "============================================================"
printf 'Wall-clock: %s seconds\n' "$((SECONDS - START_SECONDS))"
if [ "$fail" -gt 0 ]; then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
exit 0

#!/bin/bash
# Regression (me2resh/apexyard#1549): with a fake CLAUDE_CODE_SESSION_ID and a
# temp directory standing in for the real pin dir, running a representative
# hook test through the isolation helper must leave that pin directory
# byte-identical. Without the helper, the same session id lets pin-ops-root.sh
# overwrite the pin (the bug this ticket closes).

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PIN_HOOK="$SRC_ROOT/.claude/hooks/pin-ops-root.sh"
REP_TEST="$SRC_ROOT/.claude/hooks/tests/test_ops_root.sh"
HELPER="$SRC_ROOT/.claude/hooks/tests/_test-session-isolation.sh"

for f in "$PIN_HOOK" "$REP_TEST" "$HELPER"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file missing: $f" >&2
    exit 1
  fi
done

PASS=0
FAIL=0
FAILED_CASES=""

mark_pass() { echo "  PASS $1"; PASS=$((PASS + 1)); }
mark_fail() {
  echo "  FAIL $1: $2" >&2
  FAIL=$((FAIL + 1))
  FAILED_CASES="${FAILED_CASES}${1}"$'\n'
}

dir_fingerprint() {
  # Stable fingerprint of a pin directory (paths relative + sha256 of files).
  local root="$1"
  (
    cd "$root" || exit 1
    find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r rel; do
      shasum -a 256 "$rel"
    done
  )
}

SID="regression-1549-fake-session"
VICTIM=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-1549-victim.XXXXXX") || exit 1
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")

# --- Case 1: without helper, pin-ops-root overwrites the victim pin ----------
(
  export CLAUDE_CODE_SESSION_ID="$SID"
  export APEXYARD_OPS_PIN_DIR="$VICTIM"
  unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
  cd "$SRC_ROOT" || exit 1
  bash "$PIN_HOOK"
)
pin_after_raw=$(cat "$VICTIM/ops-root-${SID}")
if [ "$pin_after_raw" != "/path/to/real/ops-fork" ]; then
  mark_pass "without helper, pin-ops-root overwrites victim pin (bug reproduced)"
else
  mark_fail "without helper overwrite" \
    "expected pin-ops-root to replace sentinel; still='$pin_after_raw'"
fi

# Restore victim to the sentinel state for the isolation cases.
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")

# --- Case 2: with helper sourced, same pin-ops-root leaves victim untouched -
(
  export CLAUDE_CODE_SESSION_ID="$SID"
  export APEXYARD_OPS_PIN_DIR="$VICTIM"
  unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
  # shellcheck disable=SC1090,SC1091
  . "$HELPER"
  cd "$SRC_ROOT" || exit 1
  bash "$PIN_HOOK"
)
VICTIM_AFTER_HELPER=$(dir_fingerprint "$VICTIM")
if [ "$VICTIM_AFTER_HELPER" = "$VICTIM_BEFORE" ]; then
  mark_pass "with helper, pin-ops-root leaves victim pin dir byte-identical"
else
  mark_fail "with helper pin-ops-root" \
    "victim pin dir changed"$'\n'"BEFORE:"$'\n'"$VICTIM_BEFORE"$'\n'"AFTER:"$'\n'"$VICTIM_AFTER_HELPER"
fi

# --- Case 3: representative hook test with polluted parent env --------------
# Parent exports look like a live session pointing at the victim pin dir.
# The test file sources the helper near the top, so the victim must stay
# byte-identical after the suite finishes.
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")

if CLAUDE_CODE_SESSION_ID="$SID" \
  APEXYARD_OPS_PIN_DIR="$VICTIM" \
  env -u APEXYARD_OPS_DISABLE_PIN -u APEXYARD_DISABLE_RESOLUTION_CACHE \
  bash "$REP_TEST" >/tmp/_1549_rep_test.out 2>&1; then
  VICTIM_AFTER_REP=$(dir_fingerprint "$VICTIM")
  if [ "$VICTIM_AFTER_REP" = "$VICTIM_BEFORE" ]; then
    mark_pass "representative test_ops_root.sh leaves victim pin dir byte-identical"
  else
    mark_fail "representative suite mutated victim" \
      "victim pin dir changed"$'\n'"BEFORE:"$'\n'"$VICTIM_BEFORE"$'\n'"AFTER:"$'\n'"$VICTIM_AFTER_REP"
  fi
else
  mark_fail "representative suite" \
    "test_ops_root.sh failed; tail:"$'\n'"$(tail -n 20 /tmp/_1549_rep_test.out)"
fi

# --- Case 4: runner-style env wrapper also protects the victim --------------
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")
RUNNER_PIN=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-1549-runner-pins.XXXXXX") || exit 1

if CLAUDE_CODE_SESSION_ID="$SID" APEXYARD_OPS_PIN_DIR="$VICTIM" \
  env -u CLAUDE_CODE_SESSION_ID \
    APEXYARD_OPS_DISABLE_PIN=1 \
    APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
    APEXYARD_OPS_PIN_DIR="$RUNNER_PIN" \
    bash "$REP_TEST" >/tmp/_1549_runner_wrap.out 2>&1; then
  VICTIM_AFTER_RUNNER=$(dir_fingerprint "$VICTIM")
  if [ "$VICTIM_AFTER_RUNNER" = "$VICTIM_BEFORE" ]; then
    mark_pass "runner-style env wrapper leaves victim pin dir byte-identical"
  else
    mark_fail "runner-style wrapper" \
      "victim pin dir changed"$'\n'"BEFORE:"$'\n'"$VICTIM_BEFORE"$'\n'"AFTER:"$'\n'"$VICTIM_AFTER_RUNNER"
  fi
else
  mark_fail "runner-style wrapper" \
    "test_ops_root.sh failed; tail:"$'\n'"$(tail -n 20 /tmp/_1549_runner_wrap.out)"
fi

echo
echo "session-isolation regression: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n%s' "$FAILED_CASES" >&2
  exit 1
fi
exit 0

#!/bin/bash
# Regression (me2resh/apexyard#1549): with a fake CLAUDE_CODE_SESSION_ID and a
# temp directory standing in for the real pin dir, running a write-capable
# hook path through the isolation helper must leave that pin directory
# byte-identical. Without the helper, the same session id lets pin-ops-root.sh
# overwrite the pin (the bug this ticket closes).
#
# Cases 3–4 intentionally use a mini suite that *writes* (pin-ops-root), not
# a read-only lib smoke test — test_ops_root.sh never mutates the pin dir, so
# "victim unchanged" would pass even with the helper removed (vacuous).

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
PIN_HOOK="$SRC_ROOT/.claude/hooks/pin-ops-root.sh"
HELPER="$SRC_ROOT/.claude/hooks/tests/_test-session-isolation.sh"

for f in "$PIN_HOOK" "$HELPER"; do
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

# --- Case 3: write-capable mini suite WITH helper (parent env polluted) -----
# Parent exports look like a live session pointing at the victim pin dir.
# The child re-exports the session id and clears DISABLE_PIN (the shape a
# forgetful pin test might take) but must still write only into the helper's
# temp pin dir — never the victim.
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")

MINI_WITH=$(mktemp "${TMPDIR:-/tmp}/apexyard-1549-mini-with.XXXXXX") || exit 1
cat >"$MINI_WITH" <<EOF
#!/bin/bash
set -u
# Mini suite lives under TMPDIR; source the real helper by absolute path
# (production suites use dirname "\${BASH_SOURCE[0]:-\$0}" next to themselves).
# shellcheck disable=SC1090,SC1091
. "$HELPER"
# Re-export session id and clear DISABLE_PIN the way a pin-behaviour case
# does, but deliberately omit a private APEXYARD_OPS_PIN_DIR — the helper's
# temp pin dir must absorb the write.
export CLAUDE_CODE_SESSION_ID="$SID"
unset APEXYARD_OPS_DISABLE_PIN
cd "$SRC_ROOT" || exit 1
bash "$PIN_HOOK"
EOF

if CLAUDE_CODE_SESSION_ID="$SID" \
  APEXYARD_OPS_PIN_DIR="$VICTIM" \
  env -u APEXYARD_OPS_DISABLE_PIN -u APEXYARD_DISABLE_RESOLUTION_CACHE \
  bash "$MINI_WITH" >/tmp/_1549_mini_with.out 2>&1; then
  VICTIM_AFTER_MINI=$(dir_fingerprint "$VICTIM")
  if [ "$VICTIM_AFTER_MINI" = "$VICTIM_BEFORE" ]; then
    mark_pass "write-capable mini suite with helper leaves victim pin dir byte-identical"
  else
    mark_fail "mini suite with helper mutated victim" \
      "victim pin dir changed"$'\n'"BEFORE:"$'\n'"$VICTIM_BEFORE"$'\n'"AFTER:"$'\n'"$VICTIM_AFTER_MINI"
  fi
else
  mark_fail "mini suite with helper" \
    "mini suite failed; tail:"$'\n'"$(tail -n 20 /tmp/_1549_mini_with.out)"
fi
rm -f "$MINI_WITH"

# --- Case 3b: same mini suite WITHOUT helper mutates the victim -------------
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")

MINI_WITHOUT=$(mktemp "${TMPDIR:-/tmp}/apexyard-1549-mini-without.XXXXXX") || exit 1
cat >"$MINI_WITHOUT" <<EOF
#!/bin/bash
set -u
export CLAUDE_CODE_SESSION_ID="$SID"
unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
cd "$SRC_ROOT" || exit 1
bash "$PIN_HOOK"
EOF

CLAUDE_CODE_SESSION_ID="$SID" \
  APEXYARD_OPS_PIN_DIR="$VICTIM" \
  env -u APEXYARD_OPS_DISABLE_PIN -u APEXYARD_DISABLE_RESOLUTION_CACHE \
  bash "$MINI_WITHOUT" >/tmp/_1549_mini_without.out 2>&1 || true
pin_after_mini=$(cat "$VICTIM/ops-root-${SID}")
if [ "$pin_after_mini" != "/path/to/real/ops-fork" ]; then
  mark_pass "write-capable mini suite without helper overwrites victim pin"
else
  mark_fail "mini suite without helper" \
    "expected overwrite; pin still='$pin_after_mini'; tail:"$'\n'"$(tail -n 20 /tmp/_1549_mini_without.out)"
fi
rm -f "$MINI_WITHOUT"

# --- Case 4: runner-style env wrapper also protects the victim --------------
printf '%s\n' "/path/to/real/ops-fork" >"$VICTIM/ops-root-${SID}"
printf 'cache-sentinel\n' >"$VICTIM/resolve-cache-${SID}-config-json"
VICTIM_BEFORE=$(dir_fingerprint "$VICTIM")
RUNNER_PIN=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-1549-runner-pins.XXXXXX") || exit 1

MINI_RUNNER=$(mktemp "${TMPDIR:-/tmp}/apexyard-1549-mini-runner.XXXXXX") || exit 1
cat >"$MINI_RUNNER" <<EOF
#!/bin/bash
set -u
export CLAUDE_CODE_SESSION_ID="$SID"
unset APEXYARD_OPS_DISABLE_PIN APEXYARD_DISABLE_RESOLUTION_CACHE
cd "$SRC_ROOT" || exit 1
bash "$PIN_HOOK"
EOF

if CLAUDE_CODE_SESSION_ID="$SID" APEXYARD_OPS_PIN_DIR="$VICTIM" \
  env -u CLAUDE_CODE_SESSION_ID \
    APEXYARD_OPS_DISABLE_PIN=1 \
    APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
    APEXYARD_OPS_PIN_DIR="$RUNNER_PIN" \
    bash "$MINI_RUNNER" >/tmp/_1549_runner_wrap.out 2>&1; then
  VICTIM_AFTER_RUNNER=$(dir_fingerprint "$VICTIM")
  if [ "$VICTIM_AFTER_RUNNER" = "$VICTIM_BEFORE" ]; then
    mark_pass "runner-style env wrapper leaves victim pin dir byte-identical"
  else
    mark_fail "runner-style wrapper" \
      "victim pin dir changed"$'\n'"BEFORE:"$'\n'"$VICTIM_BEFORE"$'\n'"AFTER:"$'\n'"$VICTIM_AFTER_RUNNER"
  fi
else
  # pin-ops-root is a silent no-op without CLAUDE_CODE_SESSION_ID (runner unsets it)
  # so a non-zero exit would be unexpected; still report.
  mark_fail "runner-style wrapper" \
    "mini suite failed; tail:"$'\n'"$(tail -n 20 /tmp/_1549_runner_wrap.out)"
fi
rm -f "$MINI_RUNNER"

echo
echo "session-isolation regression: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'Failed cases:\n%s' "$FAILED_CASES" >&2
  exit 1
fi
exit 0

#!/bin/bash
# Tests bin/conformance-assert-block-message.sh — the helper the
# conformance CI workflow (.github/workflows/conformance.yml, #871) uses
# to assert a harness transcript contains block-git-add-all.sh's real,
# live-captured block message rather than a hardcoded copy of it.
#
# What this proves:
#   1. --print actually runs the real hook and returns exit 0 with output
#      containing the expected anchor substring.
#   2. --check passes against a transcript containing the anchor.
#   3. --check fails against a transcript that does NOT contain the anchor
#      (the harness self-block / fail-closed / no-op case).
#   4. --check fails loudly against a missing transcript file.
#   5. The script's own live-derived message tracks the hook: if the hook's
#      wording changes, this test (via --print) changes with it — nothing
#      here hardcodes a second copy of the message.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HELPER="$ROOT/bin/conformance-assert-block-message.sh"

PASS=0
FAIL=0
FAILED_CASES=""

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_CASES="$FAILED_CASES\n  - $desc (expected '$expected', got '$actual')"
  fi
}

[ -f "$HELPER" ] || { echo "FATAL: helper script not found: $HELPER"; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# --- Case 1: --print runs the real hook and exits 0 -------------------------
print_out="$(bash "$HELPER" --print 2>&1)"
print_rc=$?
assert_eq "case1: --print exits 0" "0" "$print_rc"
case "$print_out" in
  *"are forbidden"*) PASS=$((PASS + 1)) ;;
  *) FAIL=$((FAIL + 1)); FAILED_CASES="$FAILED_CASES\n  - case1: --print output missing expected anchor substring" ;;
esac

# --- Case 2: --check passes when the transcript contains the anchor --------
pass_transcript="$TMPDIR/pass.log"
printf '2026-07-12T00:00:00Z run-log: BLOCKED: '"'"'git add -A'"'"', '"'"'git add --all'"'"', and '"'"'git add .'"'"' are forbidden.\nnothing staged.\n' > "$pass_transcript"
bash "$HELPER" --check "$pass_transcript" >/dev/null 2>&1
assert_eq "case2: --check passes on a transcript containing the anchor" "0" "$?"

# --- Case 3: --check fails when the transcript does NOT contain the anchor -
fail_transcript="$TMPDIR/fail.log"
printf 'agent ran git add -A cleanly, nothing blocked, all good\n' > "$fail_transcript"
bash "$HELPER" --check "$fail_transcript" >/dev/null 2>&1
assert_eq "case3: --check fails on a transcript missing the anchor" "1" "$?"

# --- Case 4: --check fails loudly on a missing transcript file -------------
bash "$HELPER" --check "$TMPDIR/does-not-exist.log" >/dev/null 2>&1
assert_eq "case4: --check fails on a missing transcript file" "1" "$?"

# --- Case 5: --check requires an argument -----------------------------------
bash "$HELPER" --check >/dev/null 2>&1
assert_eq "case5: --check with no path exits non-zero (usage error)" "2" "$?"

# --- Case 6: unknown flag rejected ------------------------------------------
bash "$HELPER" --bogus >/dev/null 2>&1
assert_eq "case6: unknown flag exits non-zero" "2" "$?"

echo ""
echo "test_conformance_assert_block_message.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo -e "Failed cases:$FAILED_CASES"
  exit 1
fi
exit 0

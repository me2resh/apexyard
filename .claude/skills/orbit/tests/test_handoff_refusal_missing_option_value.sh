#!/bin/bash
# test_handoff_refusal_missing_option_value.sh — a missing option value
# (e.g. --slice as the last argument) must exit 13 immediately, not loop
# forever (apexyard#1446, Rex round-2 Issue 3).
#
# `shift 2` with only one positional argument left is a no-op in bash (it
# errors and leaves $@ unchanged), so the old parser's while loop never
# advanced. This test uses `timeout` as a hang detector: if the helper is
# still running after a few seconds, the test fails outright rather than
# hanging the suite.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

fail=0

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
fi

run_with_hang_guard() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 5 "$HELPER" "$@"
  else
    # No timeout/gtimeout on this machine: run in the background and kill it
    # if it is still alive after 5 seconds, so a regression still fails
    # loudly instead of hanging the whole suite.
    "$HELPER" "$@" &
    hpid=$!
    ( sleep 5; kill -0 "$hpid" 2>/dev/null && kill -9 "$hpid" 2>/dev/null ) &
    watcher=$!
    wait "$hpid" 2>/dev/null
    rc=$?
    kill "$watcher" 2>/dev/null
    return "$rc"
  fi
}

stderr_file=$(mktemp "${TMPDIR:-/tmp}/orbit-handoff-missing-value.XXXXXX")

output=$(run_with_hang_guard --slice 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
  echo "FAIL: helper hung on a missing --slice value (timed out, rc=$rc)"
  fail=1
elif [ "$rc" -ne 13 ]; then
  echo "FAIL: expected exit 13 (usage error), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"Usage: handoff-preflight.sh"*) ;;
  *) echo "FAIL: stderr does not carry the usage message: $stderr_output"; fail=1 ;;
esac

output2=$(run_with_hang_guard --repo 2>"$stderr_file")
rc2=$?
stderr_output2=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc2" -eq 124 ] || [ "$rc2" -eq 137 ]; then
  echo "FAIL: helper hung on a missing --repo value (timed out, rc=$rc2)"
  fail=1
elif [ "$rc2" -ne 13 ]; then
  echo "FAIL: expected exit 13 for a missing --repo value, got $rc2 (stdout: $output2, stderr: $stderr_output2)"
  fail=1
fi

rm -f "$stderr_file"

if [ "$fail" -eq 0 ]; then
  echo "PASS: a missing option value exits 13 immediately instead of hanging"
fi
exit "$fail"

#!/bin/bash
# The committed-overlay test must fail on a missing tracked file and stay isolated.
set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/_test-session-isolation.sh"


ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TEST_SCRIPT=${TEST_SCRIPT_OVERRIDE:-$ROOT/.claude/hooks/tests/test_sync_cursor_adapter.sh}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

if grep -Fq 'checkout-index' "$TEST_SCRIPT"; then
  echo 'FAIL: committed-overlay test may write through git checkout-index' >&2
  fail=$((fail + 1))
else
  echo 'PASS: committed-overlay test has no checkout-index write'
  pass=$((pass + 1))
fi

if grep -Fq '/tmp/_cursor_adapter_' "$TEST_SCRIPT"; then
  echo 'FAIL: committed-overlay test uses a fixed /tmp output path' >&2
  fail=$((fail + 1))
else
  echo 'PASS: committed-overlay test has no fixed /tmp output path'
  pass=$((pass + 1))
fi

mkdir -p "$TMP/missing"
if COMMITTED_ROOT_OVERRIDE="$TMP/missing" COMMITTED_CHECK_ONLY=1 \
    TMPDIR="$TMP" /bin/bash "$TEST_SCRIPT" >"$TMP/check.out" 2>&1; then
  echo 'FAIL: missing .cursorignore passed the committed-overlay check' >&2
  fail=$((fail + 1))
elif grep -Fq 'COMMITTED_CHECK: FAIL missing or drifted overlay' "$TMP/check.out"; then
  echo 'PASS: missing .cursorignore fails the committed-overlay check'
  pass=$((pass + 1))
else
  echo 'FAIL: committed-overlay check did not report the missing file' >&2
  fail=$((fail + 1))
fi

printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

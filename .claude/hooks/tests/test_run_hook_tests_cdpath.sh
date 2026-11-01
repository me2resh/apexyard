#!/bin/bash
# Regression (#1938): exported CDPATH must not corrupt runner/suite paths.
set -euo pipefail

# Resolve this test's paths before deliberately exporting a hostile CDPATH.
unset CDPATH HOOK_TEST_SHARD HOOK_TEST_SHARDS
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
OUTPUT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/run-hook-tests-cdpath.XXXXXX")
trap 'rm -rf "$OUTPUT_DIR"' EXIT
cd "$ROOT"

export CDPATH=.
FAIL=0

# --list exercises the real runner's startup without recursively running us.
if bash bin/run-hook-tests.sh --list >"$OUTPUT_DIR/list.log" 2>&1 &&
    grep -qxF '.claude/hooks/tests/test_lib_path_resolve.sh' "$OUTPUT_DIR/list.log"; then
  echo "PASS: runner starts with exported CDPATH"
else
  echo "FAIL: runner startup with exported CDPATH" >&2
  cat "$OUTPUT_DIR/list.log" >&2
  FAIL=$((FAIL + 1))
fi

# Execute the runner's launch command directly to test its environment boundary.
# This catches a missing -u CDPATH even if runner startup still clears CDPATH.
SUITE_COMMAND=$(sed -n '/^  if env -u CLAUDE_CODE_SESSION_ID /,/; then$/p' bin/run-hook-tests.sh |
  sed '1s/^  if //; $s/; then$//')
if [ -z "$SUITE_COMMAND" ]; then
  echo "FAIL: could not extract the runner's suite launch command" >&2
  exit 1
fi

# Variables consumed by the extracted command, just as in the runner.
# shellcheck disable=SC2034
t='.claude/hooks/tests/test_lib_path_resolve.sh'
# shellcheck disable=SC2034
TIMEOUT_BIN=''
# shellcheck disable=SC2034
SUITE_PIN_DIR="$OUTPUT_DIR"
# shellcheck disable=SC2034
output="$OUTPUT_DIR/suite.log"
if eval "$SUITE_COMMAND"; then
  echo "PASS: runner launch command runs a relative suite with exported CDPATH"
  tail -n 4 "$output"
else
  echo "FAIL: runner launch command with exported CDPATH" >&2
  cat "$output" >&2
  FAIL=$((FAIL + 1))
fi

exit "$FAIL"

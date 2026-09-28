#!/bin/bash
# test_handoff_refusal_duplicate_search_fails.sh — a failing duplicate-issue
# search must stop the handoff, not be treated as "no duplicate found"
# (apexyard#1446, Rex round-2 Issue 1 / Hakim M2: the search failed open).
#
# No network. Mocks `gh issue list` to exit non-zero (simulating an auth,
# network, or rate-limit failure).

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb" 0 0
fixtures_install_mock_gh "$sb"

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit"
export ORBIT_BIN

export MOCK_GH_FAIL=1
stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)
unset MOCK_GH_FAIL

if [ "$rc" -ne 13 ]; then
  echo "FAIL: expected exit 13 (cannot verify), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"Cannot verify whether an open issue"*) ;;
  *) echo "FAIL: stderr does not report the search failure as unverifiable: $stderr_output"; fail=1 ;;
esac

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when the search fails, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: a failed duplicate-issue search blocks instead of allowing through"
fi
exit "$fail"

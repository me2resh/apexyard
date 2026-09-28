#!/bin/bash
# test_handoff_refusal_duplicate_slice.sh — /orbit handoff refuses when an
# open issue already carries this slice ID (apexyard#1446).
#
# No network. Mocks `gh issue list --search <slice-id>` to return one open
# issue, and `orbit validate` to succeed, so the duplicate check is the
# refusal actually exercised.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb" 0 0
fixtures_install_mock_gh "$sb" 1

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit"
export ORBIT_BIN

stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -ne 12 ]; then
  echo "FAIL: expected exit 12 (duplicate slice), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"already carries slice ID"*"slice-demo-widget-o1"*) ;;
  *) echo "FAIL: stderr does not name the duplicate slice: $stderr_output"; fail=1 ;;
esac

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when a duplicate is found, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: handoff refuses when an open issue already carries the slice ID"
fi
exit "$fail"

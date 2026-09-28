#!/bin/bash
# test_handoff_refusal_validate_fails.sh — /orbit handoff stops and states
# the reason when `orbit validate` fails (apexyard#1446, ac1-3).
#
# No network. Mocks `orbit validate` to exit non-zero with a fixture reason.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb" 1 0
fixtures_install_mock_gh "$sb" 0

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit"
export ORBIT_BIN

stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -ne 11 ]; then
  echo "FAIL: expected exit 11 (validate failed), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"orbit validate failed"*"fixture validation failure"*) ;;
  *) echo "FAIL: stderr does not state the validate failure reason: $stderr_output"; fail=1 ;;
esac

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when validate fails, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: handoff stops and states the reason when orbit validate fails"
fi
exit "$fail"

#!/bin/bash
# test_handoff_preflight_happy_path.sh — /orbit handoff preflight, happy path
# (apexyard#1446, ac1-1, ac1-2, ac1-6).
#
# No duplicate issue, validate succeeds, dry-run sync succeeds: the helper
# must exit 0 and print the preview JSON on stdout.
#
# No network. Mocks `orbit` and `gh` on PATH inside a throwaway sandbox.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb" 0 0
fixtures_install_mock_gh "$sb" 0

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit"
export ORBIT_BIN

stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -ne 0 ]; then
  echo "FAIL: expected exit 0, got $rc (stderr: $stderr_output)"
  fail=1
fi

case "$output" in
  *"slice-demo-widget-o1"*) ;;
  *) echo "FAIL: preview does not mention the slice id"; fail=1 ;;
esac

case "$output" in
  *'"dryRun":true'*) ;;
  *) echo "FAIL: preview does not report dryRun:true"; fail=1 ;;
esac

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: handoff preflight happy path"
fi
exit "$fail"

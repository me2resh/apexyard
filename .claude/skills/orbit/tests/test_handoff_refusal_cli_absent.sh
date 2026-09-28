#!/bin/bash
# test_handoff_refusal_cli_absent.sh — /orbit handoff refuses with one
# install note when the ORBIT CLI is absent (apexyard#1446, ac1-4).
#
# No network. Points ORBIT_BIN at a path that does not exist.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_gh "$sb" 0

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit-does-not-exist"
export ORBIT_BIN

stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -ne 10 ]; then
  echo "FAIL: expected exit 10 (CLI absent), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"ORBIT CLI not found"*) ;;
  *) echo "FAIL: stderr does not carry the install note: $stderr_output"; fail=1 ;;
esac

# Exactly one install-note line, not a multi-line dump.
note_lines=$(printf '%s\n' "$stderr_output" | grep -c "ORBIT CLI not found")
if [ "$note_lines" != "1" ]; then
  echo "FAIL: expected exactly one install-note line, found $note_lines"
  fail=1
fi

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when the CLI is absent, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: handoff refuses with one install note when the CLI is absent"
fi
exit "$fail"

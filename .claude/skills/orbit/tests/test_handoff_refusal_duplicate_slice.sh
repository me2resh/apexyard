#!/bin/bash
# test_handoff_refusal_duplicate_slice.sh — /orbit handoff refuses only when
# an open issue's body contains the EXACT backtick-quoted slice-ID token the
# adapter renders under "Orbit identifiers" (apexyard#1446, Rex round-2
# Issue 1 / Hakim M2).
#
# No network. Mocks `orbit validate`/`sync` to succeed and `gh issue list`
# to return one open issue whose body carries the exact token.

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

dup_file="$sb/dup-exact.json"
cat > "$dup_file" <<'JSON'
[{"number":4242,"body":"### Orbit identifiers\n- Slice: `slice-demo-widget-o1`\n"}]
JSON

export MOCK_GH_ISSUE_LIST_JSON_FILE="$dup_file"
stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)
unset MOCK_GH_ISSUE_LIST_JSON_FILE

if [ "$rc" -ne 12 ]; then
  echo "FAIL: expected exit 12 (exact duplicate), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"already carries slice ID"*"slice-demo-widget-o1"*"exact token match"*) ;;
  *) echo "FAIL: stderr does not name the exact-match duplicate: $stderr_output"; fail=1 ;;
esac

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when a duplicate is found, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: handoff refuses when an open issue carries the exact slice-ID token"
fi
exit "$fail"

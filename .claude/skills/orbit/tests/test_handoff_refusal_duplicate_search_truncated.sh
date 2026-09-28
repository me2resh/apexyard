#!/bin/bash
# test_handoff_refusal_duplicate_search_truncated.sh — a duplicate-issue
# search that returns exactly 200 results (the helper's own --limit) must
# refuse, because the real result set may be cut off and a duplicate could
# exist past the window (apexyard#1446, Rex round-4 advisory N-adjacent).
#
# No network. Mocks `gh issue list` to return exactly 200 synthetic open
# issues, none of which carries the exact slice-ID token, so the ordinary
# exact-match filter alone would find zero and (wrongly) let the handoff
# through.

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

dup_file="$sb/dup-200.json"
jq -n '[range(200) | {number: (1000 + .), body: "### Orbit identifiers\n- Slice: `slice-unrelated-\(.)`\n"}]' > "$dup_file"
count=$(jq 'length' "$dup_file")
if [ "$count" != "200" ]; then
  echo "FAIL: test fixture setup error, expected 200 synthetic issues, built $count"
  fail=1
fi

export MOCK_GH_ISSUE_LIST_JSON_FILE="$dup_file"
stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)
unset MOCK_GH_ISSUE_LIST_JSON_FILE

if [ "$rc" -ne 13 ]; then
  echo "FAIL: expected exit 13 (search may be truncated), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"may be cut off"*) ;;
  *) echo "FAIL: stderr does not report the truncation refusal: $stderr_output"; fail=1 ;;
esac

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when the search may be truncated, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: a duplicate search returning exactly the configured limit refuses instead of assuming no duplicate"
fi
exit "$fail"

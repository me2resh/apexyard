#!/bin/bash
# test_handoff_allows_duplicate_prefix_match.sh — a different slice ID that
# shares words (a prefix/superstring, e.g. a later "-mapping" slice) with an
# open issue's body must NOT be refused as a duplicate (apexyard#1446, Rex
# round-2 Issue 1: the free-text search matched #1446 for other slice IDs
# that merely share words).
#
# No network. The mocked open issue's body carries a DIFFERENT (superstring)
# token than our slice's exact id, so the exact-match check must let this
# handoff through to the dry-run preview.

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

# Our slice id is slice-demo-widget-o1. This open issue carries the
# superstring slice-demo-widget-o1-mapping — shares every word, but is not
# the same token.
dup_file="$sb/dup-prefix.json"
cat > "$dup_file" <<'JSON'
[{"number":99,"body":"### Orbit identifiers\n- Slice: `slice-demo-widget-o1-mapping`\n"}]
JSON

export MOCK_GH_ISSUE_LIST_JSON_FILE="$dup_file"
stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$orbit_root/slices/slice-demo-o1.json" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)
unset MOCK_GH_ISSUE_LIST_JSON_FILE

if [ "$rc" -ne 0 ]; then
  echo "FAIL: expected exit 0 (no exact duplicate), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$output" in
  *"slice-demo-widget-o1"*) ;;
  *) echo "FAIL: preview does not mention the slice id: $output"; fail=1 ;;
esac

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: a prefix/superstring match does not refuse a different slice"
fi
exit "$fail"

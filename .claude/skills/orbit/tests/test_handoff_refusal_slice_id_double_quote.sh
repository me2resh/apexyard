#!/bin/bash
# test_handoff_refusal_slice_id_double_quote.sh — a slice id containing a
# double quote (on a line after an embedded newline) must refuse before any
# tracker search runs (apexyard#1446, Rex round-3 regression on the N3
# guard, fixed at round 4).
#
# A lone double quote on a SINGLE-line id was already rejected by the old
# per-line regex (the whole line fails the ^...$ anchors). The regression is
# specific to a MULTI-line id: `grep -q` succeeds if ANY line matches, so a
# clean first line ("slice-ok") let a second, quote-carrying line through.
# That quote could otherwise close the quoted search term the helper builds
# for the duplicate-issue search early, letting the remainder of the id act
# as extra search syntax. The byte-level `tr -d` check must catch the whole
# multi-line value before that search ever runs.
#
# No network. Confirms the mock duplicate-issue search is never invoked by
# checking a call-marker file the mock `gh` writes on every invocation.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/handoff-preflight.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
fixtures_install_mock_orbit "$sb" 0 0

call_marker="$sb/gh-was-called"
mkdir -p "$sb/bin"
cat > "$sb/bin/gh" <<EOF
#!/bin/bash
touch "$call_marker"
echo '[]'
exit 0
EOF
chmod +x "$sb/bin/gh"

slice_file="$sb/slice-quote.json"
jq -n '{
  specVersion: "0.1",
  id: "slice-ok\n\"evil",
  planId: "plan-demo-widget",
  outcomeId: "o1-demo",
  basedOn: {
    planRevision: 1,
    reconciliationId: "reconciliation-demo-widget-r1",
    repositories: { "demo-widget": "0000000000000000000000000000000000000a" }
  },
  objective: "Fixture objective for the handoff smoke test.",
  why: "Fixture reason.",
  contributesTo: ["ac1-1"],
  scope: { include: ["fixture item"], exclude: ["fixture excluded item"] }
}' > "$slice_file"

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit"
export ORBIT_BIN

stderr_file="$sb/stderr.log"
output=$("$HELPER" --slice "$slice_file" --repo demo-org/demo-widget --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -ne 13 ]; then
  echo "FAIL: expected exit 13 for a double quote in the slice id, got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"contains characters outside"*) ;;
  *) echo "FAIL: stderr does not report the character-class refusal: $stderr_output"; fail=1 ;;
esac

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview, got: $output"
  fail=1
fi

if [ -f "$call_marker" ]; then
  echo "FAIL: the duplicate-issue search ran even though the slice id should have been rejected first"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: a double quote in the slice id is rejected before any tracker search runs"
fi
exit "$fail"

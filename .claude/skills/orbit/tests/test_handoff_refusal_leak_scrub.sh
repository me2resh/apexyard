#!/bin/bash
# test_handoff_refusal_leak_scrub.sh — the handoff must block when a
# registered private-portfolio name is the FIRST WORD of the preview body's
# "why" section (apexyard#1446, Hakim H1 / Rex round-2 Issue 2, ac1-6).
#
# In the raw JSON preview, that name is preceded by the two characters "\n"
# (a JSON-escaped newline), not a real newline — the scrub's word-boundary
# rule needs a non-alphanumeric character before the name, and "n" does not
# qualify. Scrubbing the jq -r plain-text body (with a real newline) catches
# it; scrubbing the raw JSON does not. This test proves the shipped helper
# takes the plain-text path and blocks.
#
# No network. Builds a self-contained sandboxed copy of the real leak-scrub
# hook AND this helper, at the same relative depth they have in this repo
# (.claude/hooks/check-private-refs-runtime.sh and
# .claude/skills/orbit/lib/handoff-preflight.sh), so the helper's own
# self-location path resolution finds the SANDBOXED scrub and a SYNTHETIC
# registry — never the real fork's.

set -u

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0
private_name="zephyrvault"
private_repo="acme-private/zephyrvault"

sb=$(make_sandbox)
orbit_root=$(fixtures_write_orbit_root "$sb")
helper=$(fixtures_install_leak_scrub_sandbox "$sb" "$private_name" "$private_repo")
fixtures_install_mock_orbit_with_leak "$sb" "Zephyrvault"
fixtures_install_mock_gh "$sb"

PATH="$sb/bin:$PATH"
export PATH
ORBIT_BIN="$sb/bin/orbit"
export ORBIT_BIN

# The target repo must be one the scrub treats as public (its hardcoded
# default is me2resh/apexyard) so the scrub actually runs instead of no-op'ing
# for an unrecognized repo.
stderr_file="$sb/stderr.log"
output=$("$helper" --slice "$orbit_root/slices/slice-demo-o1.json" --repo me2resh/apexyard --orbit-root "$orbit_root" 2>"$stderr_file")
rc=$?
stderr_output=$(cat "$stderr_file" 2>/dev/null)

if [ "$rc" -ne 14 ]; then
  echo "FAIL: expected exit 14 (leak scrub blocked), got $rc (stdout: $output, stderr: $stderr_output)"
  fail=1
fi

case "$stderr_output" in
  *"BLOCKED"*"leak scrub blocked the handoff preview"*) ;;
  *) echo "FAIL: stderr does not report a leak-scrub block: $stderr_output"; fail=1 ;;
esac

# The diagnostic must withhold the matched identifier itself.
if printf '%s' "$stderr_output" | grep -qi "$private_name"; then
  echo "FAIL: stderr disclosed the private name it was supposed to withhold: $stderr_output"
  fail=1
fi

if [ -n "$output" ]; then
  echo "FAIL: expected no stdout preview when the leak scrub blocks, got: $output"
  fail=1
fi

rm -rf "$sb"

if [ "$fail" -eq 0 ]; then
  echo "PASS: a private name as the first word of why blocks the handoff"
fi
exit "$fail"

#!/bin/bash
# Pins Rex's evidence-citation grounding contract (me2resh/apexyard#1189).

set -u

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REX="$ROOT/.claude/agents/code-reviewer.md"
FAIL=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

require_text() {
  local text="$1" description="$2"
  if grep -qF "$text" "$REX"; then
    pass "$description"
  else
    fail "$description"
  fi
}

if [ ! -f "$REX" ]; then
  fail "Rex agent prompt exists"
  exit "$FAIL"
fi

require_text '## Evidence citations — read the criterion' \
  'Rex has an evidence-citation grounding section'
require_text 'read the cited region in full before asserting what it does' \
  'Rex reads cited evidence before making a mechanism claim'
require_text 'A section header, scope line, table heading, or gate lead-in is not the mechanism.' \
  'Rex does not treat a header or lead-in as a criterion'
require_text 'Verify the applicable criterion, including its conditions and exceptions' \
  'Rex verifies all applicable criterion clauses'
require_text 'cite the line where that criterion lives' \
  'Rex cites the line containing the criterion'
require_text 'Do not assert that a condition is absent until you have read the region where it could be defined.' \
  'Rex verifies a condition before asserting its absence'

printf '\nEvidence-grounding checks completed with %s failure(s).\n' "$FAIL"
exit "$FAIL"

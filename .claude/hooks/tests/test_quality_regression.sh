#!/bin/bash
# Static tests for the cross-harness quality regression (me2resh/apexyard#1165):
# the runner parses every fixture case and builds its prompt, the corpus index
# covers every case, the docs and decision record exist, and the release
# process points at the check. No harness is invoked.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
RUNNER="$SRC_ROOT/bin/quality-regression.sh"
INDEX="$SRC_ROOT/docs/quality-regression/corpus.md"
README="$SRC_ROOT/docs/quality-regression/README.md"
AGDR="$SRC_ROOT/docs/agdr/AgDR-0127-cross-harness-quality-regression.md"

PASS=0; FAIL=0; FAILED=""
assert() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS [$label]"; PASS=$((PASS+1))
  else echo "FAIL [$label]" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}${label} "; fi
}

assert "runner:exists" test -x "$RUNNER"
check_out=$(bash "$RUNNER" --check-only --cases all 2>&1)
assert "runner:parses-20" bash -c "echo \"\$1\" | grep -q '^cases parsed: 20 '" _ "$check_out"
assert "runner:builds-20-prompts" bash -c "echo \"\$1\" | grep -q '^prompts built: 20'" _ "$check_out"
rep_out=$(bash "$RUNNER" --check-only 2>&1)
assert "runner:representative-8" bash -c "echo \"\$1\" | grep -q '^cases selected: 8 '" _ "$rep_out"
assert "runner:unknown-case-rejected" bash -c "! bash '$RUNNER' --check-only --cases ZZ-99 >/dev/null 2>&1"
assert "runner:no-llm-judge" grep -qF 'It does not use an LLM judge' "$RUNNER"
assert "runner:empty-change-count" grep -qF 'n=$(grep -c . "$changed" 2>/dev/null) || n=0' "$RUNNER"

# every case id the runner parsed appears in the index
for id in $(echo "$check_out" | sed -n 's/^cases parsed: 20 (\(.*\))$/\1/p'); do
  assert "index:$id" grep -qF "| $id |" "$INDEX"
done

assert "readme:exists" test -f "$README"
assert "readme:severity-gate" grep -qF 'no high-severity failure on any supported harness' "$README"
assert "readme:adjudicated-final" grep -qF 'The adjudicated column is final' "$README"
assert "readme:not-llm-judge" grep -qF 'Not an LLM-judge benchmark' "$README"
assert "release-process:step" grep -qF 'bin/quality-regression.sh' "$SRC_ROOT/docs/release-process.md"

assert "agdr:exists" test -f "$AGDR"
assert "agdr:options" grep -qE '^## Options Considered$' "$AGDR"
assert "agdr:ticket" grep -qF 'me2resh/apexyard#1165' "$AGDR"

echo ""; echo "----------------------------------------"
echo "Quality-regression smoke tests: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && { echo "Failed: $FAILED"; exit 1; }
exit 0

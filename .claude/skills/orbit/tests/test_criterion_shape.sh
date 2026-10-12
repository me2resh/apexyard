#!/bin/bash
# Check advisory warnings without changing the CLI result.
set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/warn-criterion-shape.sh"
# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0
sb=$(make_sandbox)
trap 'rm -rf "$sb"' EXIT
orbit_root=$(fixtures_write_orbit_root "$sb")
plan="$orbit_root/plans/plan-demo-widget.r1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"

check() {
  label="$1"
  expected="$2"
  pattern="$3"
  shift 3
  output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" "$@" 2>&1)
  rc=$?
  count=$(printf '%s\n' "$output" | grep -c '^WARNING: ORBIT criterion ' || true)
  if [ "$rc" -ne 0 ] || [ "$count" -ne "$expected" ]; then
    echo "FAIL: $label (exit $rc, warnings $count): $output"
    fail=1
  fi
  if [ "$expected" -gt 0 ]; then
    if ! printf '%s\n' "$output" | grep -qF "$pattern" ||
       ! printf '%s\n' "$output" | grep -q 'Plan plan-demo-widget revision 1'; then
      echo "FAIL: $label omitted warning text or Plan context: $output"
      fail=1
    fi
  fi
}

write_statement() {
  jq --arg statement "$1" '.acceptanceCriteria[0].statement = $statement' \
    "$plan" > "$sb/plan.json"
  mv "$sb/plan.json" "$plan"
}

write_assessment() {
  jq --arg status "$1" --arg explanation "$2" \
    '.criterionAssessments[0] |= (.status = $status | .explanation = $explanation)' \
    "$reconciliation" > "$sb/reconciliation.json"
  mv "$sb/reconciliation.json" "$reconciliation"
}

write_assessment not-verified 'Missing: Test results. Next: Run the tests.'
check 'clean explicit records' 0 '' --plan "$plan" --reconciliation "$reconciliation"
check 'clean record set' 0 ''

fifty=$(jq -nr '[range(50) | "word"] | join(" ")')
write_statement "$fifty"
check '50 words is allowed' 0 ''
write_statement "$fifty word"
check '51 words warns' 1 'statement has 51 words; limit is 50' \
  --plan "$plan" --reconciliation "$reconciliation"
check 'record set warns' 1 'statement has 51 words; limit is 50'

write_statement 'The result is available. Shown by: test output.'
check 'embedded proof warns' 1 'statement contains Shown by:'
write_statement 'The result is available.'
for status in not-verified partially-verified contradicted; do
  write_assessment "$status" 'Test results are absent.'
  check "$status gap warns" 1 "$status explanation does not start with Missing:"
done
write_assessment achieved 'The tests passed.'
check 'achieved needs no gap prefix' 0 ''
write_assessment not-verified ''
check 'empty explanation warns' 1 'explanation does not start with Missing:'

write_statement "$fifty word Shown by: output"
check 'all three warnings remain advisory' 3 'statement contains Shown by:'

# The wiring preserves the CLI status and runs after coverage checks.
for operation in reconcile validate; do
  block=$(sed -n "/^### .*orbit $operation /,/^### /p" "$SKILL_DIR/SKILL.md")
  if ! printf '%s\n' "$block" | grep -q 'warn-criterion-shape.sh' ||
     ! printf '%s\n' "$block" | grep -q '(exit "$cli_status")'; then
    echo "FAIL: $operation omitted checker or CLI status preservation"
    fail=1
  fi
done

"$BASH" "$HELPER" --orbit-root >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  echo 'FAIL: missing option value must report an error'
  fail=1
fi
printf '{broken\n' > "$plan"
"$BASH" "$HELPER" --orbit-root "$orbit_root" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  echo 'FAIL: malformed record must report an error'
  fail=1
fi

[ "$fail" -ne 0 ] || echo 'PASS: criterion shape warnings'
exit "$fail"

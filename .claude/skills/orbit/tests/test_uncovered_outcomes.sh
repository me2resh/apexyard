#!/bin/bash
# Advisory coverage checks use local ORBIT records only.

set -u

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$SKILL_DIR/lib/warn-uncovered-outcomes.sh"

# shellcheck source=./_lib-fixtures.sh
. "$(dirname "$0")/_lib-fixtures.sh"

fail=0
sb=$(make_sandbox)
trap 'rm -rf "$sb"' EXIT
orbit_root=$(fixtures_write_orbit_root "$sb")
plan="$orbit_root/plans/plan-demo-widget.r1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"

check_warning() {
  label="$1"
  expected="$2"
  output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" --plan "$plan" \
    --reconciliation "$reconciliation" 2>&1)
  rc=$?
  count=$(printf '%s\n' "$output" | grep -c '^WARNING: ORBIT outcome o1-demo' || true)
  if [ "$rc" -ne 0 ] || [ "$count" -ne "$expected" ]; then
    echo "FAIL: $label (exit $rc, warnings $count): $output"
    fail=1
  fi
  if [ "$expected" -gt 0 ] && ! printf '%s\n' "$output" |
    grep -q 'Plan plan-demo-widget revision 1'; then
    echo "FAIL: $label omitted Plan ID and revision: $output"
    fail=1
  fi
}

rm "$slice"
check_warning 'unmet criterion without slice' 1
zero_output=$(/bin/bash "$HELPER" --orbit-root "$orbit_root" --plan "$plan" \
  --reconciliation "$reconciliation" 2>&1)
if [ "$?" -ne 0 ] || ! printf '%s\n' "$zero_output" | grep -q '^WARNING: ORBIT outcome o1-demo'; then
  echo "FAIL: Bash 3.2 zero-slice case lost its warning: $zero_output"
  fail=1
fi
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if [ "$?" -ne 0 ] || ! printf '%s' "$output" | grep -q '^WARNING: ORBIT outcome o1-demo'; then
  echo 'FAIL: record-set validation mode missed the uncovered outcome'
  fail=1
fi

# Validate checks the latest Plan revision, even when an older file is first.
orbit_root=$(fixtures_write_orbit_root "$sb")
cp "$slice" "$sb/revision-one-slice.json"
rm "$slice"
revision_two="$orbit_root/plans/plan-demo-widget.a-r2.json"
jq '.revision = 2' "$plan" > "$revision_two"
revision_two_reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r2.json"
jq '.planRevision = 2 | .id = "reconciliation-demo-widget-r2"' \
  "$reconciliation" > "$revision_two_reconciliation"
jq '.basedOn.planRevision = 2 | .basedOn.reconciliationId = "reconciliation-demo-widget-r2"' \
  "$sb/revision-one-slice.json" > "$sb/revision-two-slice.json"
mv "$sb/revision-two-slice.json" "$orbit_root/slices/slice-demo-o1.json"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if [ "$?" -ne 0 ] || printf '%s\n' "$output" | grep -q '^WARNING:'; then
  echo "FAIL: validate warned for a superseded Plan revision: $output"
  fail=1
fi
other_plan="$orbit_root/plans/plan-other-widget.r1.json"
jq '.id = "plan-other-widget" |
  .outcomes = [{"id":"o3-demo","title":"Other outcome"}] |
  .acceptanceCriteria = [{"id":"ac3-1","outcomeId":"o3-demo","statement":"Other criterion."}]' \
  "$plan" > "$other_plan"
other_reconciliation="$orbit_root/reconciliations/reconciliation-other-widget-r1.json"
jq '.id = "reconciliation-other-widget-r1" | .planId = "plan-other-widget"' \
  "$reconciliation" > "$other_reconciliation"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if [ "$?" -ne 0 ] ||
   ! printf '%s\n' "$output" | grep -q 'outcome o3-demo.*Plan plan-other-widget revision 1' ||
   printf '%s\n' "$output" | grep -q 'outcome o1-demo'; then
  echo "FAIL: validate did not check the latest revision of each Plan: $output"
  fail=1
fi
revision_two_tie="$orbit_root/plans/plan-demo-widget.r2z.json"
jq '.outcomes = [{"id":"o2-demo","title":"Second outcome"}] |
  .acceptanceCriteria = [{"id":"ac2-1","outcomeId":"o2-demo","statement":"Second criterion."}]' \
  "$revision_two" > "$revision_two_tie"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if [ "$?" -ne 0 ] ||
   ! printf '%s\n' "$output" | grep -q 'tied Plan plan-demo-widget revision 2' ||
   ! printf '%s\n' "$output" | grep -q 'outcome o2-demo.*Plan plan-demo-widget revision 2' ||
   printf '%s\n' "$output" | grep -q 'outcome o1-demo'; then
  echo "FAIL: tied latest Plan needs a diagnostic and filename-order winner: $output"
  fail=1
fi
rm "$revision_two_tie"
rm "$revision_two" "$revision_two_reconciliation" "$other_plan" "$other_reconciliation"

# A malformed slice is diagnosed once; other slices still cover their outcomes.
orbit_root=$(fixtures_write_orbit_root "$sb/malformed-slice")
plan="$orbit_root/plans/plan-demo-widget.r1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"
jq '.outcomes += [{"id":"o2-demo","title":"Second outcome"}] |
  .acceptanceCriteria += [{"id":"ac2-1","outcomeId":"o2-demo","statement":"Second criterion."}]' \
  "$plan" > "$sb/expanded-plan.json"
mv "$sb/expanded-plan.json" "$plan"
bad_slice="$orbit_root/slices/slice-broken.json"
printf '{broken\n' > "$bad_slice"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
rc=$?
bad_count=$(printf '%s\n' "$output" | grep -cF "invalid slice record: $bad_slice" || true)
if [ "$rc" -ne 0 ] || [ "$bad_count" -ne 1 ] ||
   ! printf '%s\n' "$output" | grep -q 'outcome o2-demo.*Plan plan-demo-widget revision 1' ||
   printf '%s\n' "$output" | grep -q 'outcome o1-demo'; then
  echo "FAIL: malformed slice suppressed another slice or outcome: $output"
  fail=1
fi

# A string reference is one ID, never a substring match.
orbit_root=$(fixtures_write_orbit_root "$sb/string-reference")
plan="$orbit_root/plans/plan-demo-widget.r1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"
jq '.contributesTo = "o1-demo-extra"' "$slice" > "$sb/string-slice.json"
mv "$sb/string-slice.json" "$slice"
check_warning 'longer string outcome ID does not cover' 1
jq '.contributesTo = "o1-demo"' "$slice" > "$sb/string-slice.json"
mv "$sb/string-slice.json" "$slice"
check_warning 'exact string outcome ID covers' 0
jq '.contributesTo = "ac1-1-extra"' "$slice" > "$sb/string-slice.json"
mv "$sb/string-slice.json" "$slice"
check_warning 'longer string criterion ID does not cover' 1
jq '.contributesTo = "ac1-1"' "$slice" > "$sb/string-slice.json"
mv "$sb/string-slice.json" "$slice"
check_warning 'exact string criterion ID covers' 0

# Select Reconciliations by instant, including a timezone offset.
orbit_root=$(fixtures_write_orbit_root "$sb/offset-time")
plan="$orbit_root/plans/plan-demo-widget.r1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"
rm "$slice"
jq '.criterionAssessments[0].status = "achieved"' "$reconciliation" > "$sb/older-z.json"
mv "$sb/older-z.json" "$reconciliation"
jq '.id = "reconciliation-demo-widget-offset" |
  .reconciledAt = "2026-09-28T03:30:00+03:00" |
  .criterionAssessments[0].status = "not-verified"' \
  "$reconciliation" > "$orbit_root/reconciliations/reconciliation-demo-widget-offset.json"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if [ "$?" -ne 0 ] ||
   ! printf '%s\n' "$output" | grep -q 'outcome o1-demo.*Plan plan-demo-widget revision 1'; then
  echo "FAIL: newer offset Reconciliation did not beat older Z timestamp: $output"
  fail=1
fi

orbit_root=$(fixtures_write_orbit_root "$sb")
plan="$orbit_root/plans/plan-demo-widget.r1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"
slice="$orbit_root/slices/slice-demo-o1.json"
check_warning 'criterion reference covers outcome' 0

rm "$slice"
newer="$orbit_root/reconciliations/reconciliation-demo-widget-r1-newer.json"
jq '.reconciledAt = "2026-09-28T00:00:00.370Z" | .criterionAssessments[0].status = "achieved"' \
  "$reconciliation" > "$newer"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if printf '%s\n' "$output" | grep -q '^WARNING:'; then
  echo "FAIL: latest achieved Reconciliation should suppress warning: $output"
  fail=1
fi
jq '.criterionAssessments[0].status = "not-verified"' "$newer" > "$sb/new-reconciliation.json"
mv "$sb/new-reconciliation.json" "$newer"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if ! printf '%s\n' "$output" | grep -q '^WARNING: ORBIT outcome o1-demo'; then
  echo "FAIL: latest unmet Reconciliation should warn: $output"
  fail=1
fi
tie="$orbit_root/reconciliations/reconciliation-demo-widget-r1-z-tie.json"
jq '.criterionAssessments[0].status = "achieved"' "$newer" > "$tie"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" 2>&1)
if ! printf '%s\n' "$output" | grep -q 'tied Reconciliations' || \
   printf '%s\n' "$output" | grep -q '^WARNING:'; then
  echo "FAIL: tied latest records need a diagnostic and filename-order winner: $output"
  fail=1
fi
rm "$newer" "$tie"
orbit_root=$(fixtures_write_orbit_root "$sb")
slice="$orbit_root/slices/slice-demo-o1.json"
reconciliation="$orbit_root/reconciliations/reconciliation-demo-widget-r1.json"

jq '.contributesTo = ["o1-demo"]' "$slice" > "$sb/new-slice.json"
mv "$sb/new-slice.json" "$slice"
check_warning 'outcome reference covers outcome' 0

rm "$slice"
jq '.criterionAssessments[0].status = "achieved"' "$reconciliation" > "$sb/new-reconciliation.json"
mv "$sb/new-reconciliation.json" "$reconciliation"
check_warning 'achieved criterion without slice' 0

printf '{broken\n' > "$plan"
check_warning 'malformed Plan has no warning flood' 0
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" --plan "$plan" \
  --reconciliation "$reconciliation" 2>&1)
case "$output" in
  *'invalid Plan record'*) ;;
  *) echo "FAIL: malformed Plan needs a clear message"; fail=1 ;;
esac

rm "$plan"
output=$("$BASH" "$HELPER" --orbit-root "$orbit_root" --plan "$plan" \
  --reconciliation "$reconciliation" 2>&1)
if [ "$?" -ne 0 ] || ! printf '%s' "$output" | grep -q 'no Plan record found'; then
  echo "FAIL: missing Plan needs a clear, nonblocking message"
  fail=1
fi

orbit_root=$(fixtures_write_orbit_root "$sb")
rm "$slice"
fixtures_install_mock_orbit "$sb" 0 0
ORBIT_BIN="$sb/bin/orbit"

run_cli_flow() {
  operation="$1"
  "$ORBIT_BIN" "$operation" --all --root "$orbit_root" >/dev/null 2>&1
  cli_rc=$?
  if [ "$cli_rc" -eq 0 ]; then
    if [ "$operation" = validate ]; then
      "$HELPER" --orbit-root "$orbit_root" >/dev/null 2>&1
    else
      "$HELPER" --orbit-root "$orbit_root" --plan "$plan" \
        --reconciliation "$reconciliation" >/dev/null 2>&1
    fi
  fi
  return "$cli_rc"
}

run_cli_flow validate
if [ "$?" -ne 0 ]; then
  echo 'FAIL: coverage warning changed successful validate status'
  fail=1
fi

fixtures_install_mock_orbit "$sb" 7 0
run_cli_flow validate
if [ "$?" -ne 7 ]; then
  echo 'FAIL: coverage check changed failed validate status'
  fail=1
fi

cat > "$sb/bin/orbit" <<'EOF'
#!/bin/bash
if [ "$1" = reconcile ]; then exit "${MOCK_RECONCILE_EXIT:-0}"; fi
exit 99
EOF
chmod +x "$sb/bin/orbit"
MOCK_RECONCILE_EXIT=0
export MOCK_RECONCILE_EXIT
run_cli_flow reconcile
if [ "$?" -ne 0 ]; then
  echo 'FAIL: coverage warning changed successful reconcile status'
  fail=1
fi
MOCK_RECONCILE_EXIT=9
run_cli_flow reconcile
if [ "$?" -ne 9 ]; then
  echo 'FAIL: coverage check changed failed reconcile status'
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo 'PASS: uncovered outcome warnings'
fi
exit "$fail"

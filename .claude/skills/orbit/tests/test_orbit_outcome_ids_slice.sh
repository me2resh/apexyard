#!/usr/bin/env bash
# Variables come from fixture functions.
# shellcheck disable=SC2154,SC2034
set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
candidate_write
proposal="$orbit_root/slices/slice-demo-next.json"
source_slice="$orbit_root/slices/slice-demo-o1.json"
plan="$orbit_root/plans/plan-demo-widget.r1.json"
: > "$sb/tickets"
write_proposal() {
  jq '.id="slice-demo-next" | .basedOn.reconciliationId="reconciliation-demo-new"' "$source_slice" > "$proposal"
}
write_proposal
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
jq '.outcomes += [{id:"o2-demo",title:"Second outcome"}] |
  .acceptanceCriteria += [{id:"ac2-1",outcomeId:"o2-demo",statement:"Second criterion."}]' "$plan" > "$plan.t"
mv "$plan.t" "$plan"
{
  printf '## Interview\n'
  for question in q1-outcome q2-intent q3-outcomes q4-acceptance q5-constraints q6-save; do
    printf -- '- 2026-11-12, %s: Confirmed.\n' "$question"
  done
} > "$orbit_root/plans/plan-demo-widget.notes.md"
jq '.outcomeIds=["o1-demo","o2-demo"] | .contributesTo += ["ac2-1"]' "$proposal" > "$sb/valid.json"
cp "$sb/valid.json" "$proposal"
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
for invalid in '.outcomeIds=["o2-demo","o3-demo"]' \
  '.outcomeIds=["o1-demo"]' '.outcomeIds=["o1-demo","o2-demo","o2-demo"]' \
  '.contributesTo=["ac1-1"]'; do
  jq "$invalid" "$sb/valid.json" > "$proposal"
  expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
  expect 17 --slice slice-demo-widget-o1
done
cp "$sb/valid.json" "$proposal"
mv "$plan" "$sb/plan.json"
out=$(expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets")
[[ "$out" == *'WARN [scope] Cannot read Plan'* ]] || { echo 'FAIL: Missing Plan must warn'; exit 1; }
mv "$sb/plan.json" "$plan"
# Add an open base slice whose primary is the proposal's secondary outcome.
jq '.id="slice-demo-unfiled" | .outcomeId="o2-demo" | .contributesTo=["ac2-1"]' "$source_slice" > "$sb/other.json"
blob=$(g hash-object -w "$sb/other.json")
g read-tree base
g update-index --add --cacheinfo "100644,$blob,docs/orbit/slices/slice-demo-unfiled.json"
tree=$(g write-tree)
commit=$(printf 'Concurrent proposal\n' | g commit-tree "$tree" -p base)
g update-ref refs/heads/base "$commit"
g read-tree HEAD
out=$(expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets")
[[ "$out" == *'Outcome o2-demo has an unfiled slice'* ]] || { echo 'FAIL: Missing intersecting outcome diagnostic'; exit 1; }
printf '%s\n' slice-demo-unfiled > "$sb/tickets"
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
echo 'PASS: outcomeIds proposal scope and intersection'

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
write_proposal() {
  jq '.id="slice-demo-next" | .basedOn.reconciliationId="reconciliation-demo-new"' "$source_slice" > "$proposal"
}
: > "$sb/tickets"
write_proposal
body="$sb/pr-body"
body_fail=0
: > "$body"
out=$(expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets" --pr-body "$body")
if [[ "$out" != *"records-lint: WARN [next-slice]"* ]]; then
  echo "FAIL: Missing next slice must warn."
  body_fail=1
fi
printf "No next slice: every outcome is achieved.\n" > "$body"
if ! (expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets" --pr-body "$body"); then body_fail=1; fi
printf "## Proposed next slice\n" > "$body"
out=$(expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets" --pr-body "$body")
[[ "$out" != *"records-lint: WARN [next-slice]"* ]] || { echo "FAIL: Proposal heading must not warn."; body_fail=1; }
rm "$proposal"
printf "No next slice: every outcome is achieved.\n" > "$body"
out=$(expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets" --pr-body "$body")
[[ "$out" != *"records-lint: WARN [next-slice]"* ]] || { echo "FAIL: No next slice without a record must pass."; body_fail=1; }
write_proposal
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
jq '.id="slice-demo-second"' "$proposal" > "$orbit_root/slices/second.json"
expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
rm "$orbit_root/slices/second.json"
jq '.basedOn.planRevision=2' "$proposal" > "$proposal.t"
mv "$proposal.t" "$proposal"
expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
write_proposal
jq '.basedOn.reconciliationId="reconciliation-other"' "$proposal" > "$proposal.t"
mv "$proposal.t" "$proposal"
expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
write_proposal
# Add a competing proposal on the base branch without changing the merge base.
jq '.id="slice-demo-unfiled"' "$source_slice" > "$sb/other.json"
blob=$(g hash-object -w "$sb/other.json")
g read-tree base
g update-index --add --cacheinfo "100644,$blob,docs/orbit/slices/slice-demo-unfiled.json"
tree=$(g write-tree)
commit=$(printf 'Concurrent proposal\n' | g commit-tree "$tree" -p base)
g update-ref refs/heads/base "$commit"
g read-tree HEAD
expect 17 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
printf '%s\n' slice-demo-unfiled > "$sb/tickets"
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
: > "$sb/tickets"
printf '## Withdrawn slices\n\n- Withdrawn: slice-demo-unfiled\n' >> "$orbit_root/plans/plan-demo-widget.notes.md"
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
[ "$body_fail" -eq 0 ] || exit 1
echo 'PASS proposal rules, withdrawal, and delivered own slice.'

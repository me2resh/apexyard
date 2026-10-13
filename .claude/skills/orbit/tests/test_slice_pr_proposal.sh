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
printf '## Withdrawn slices\n\n- Withdrawn: slice-demo-unfiled\n' > "$sb/notes"
blob=$(g hash-object -w "$sb/notes")
g read-tree base
g update-index --add --cacheinfo "100644,$blob,docs/orbit/plans/plan-demo-widget.notes.md"
tree=$(g write-tree)
commit=$(printf 'Withdraw proposal\n' | g commit-tree "$tree" -p base)
g update-ref refs/heads/base "$commit"
g read-tree HEAD
expect 0 --slice slice-demo-widget-o1 --tickets "$sb/tickets"
echo 'PASS proposal rules, withdrawal, and delivered own slice.'

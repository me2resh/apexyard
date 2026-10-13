#!/usr/bin/env bash
# Variables come from fixture functions.
# shellcheck disable=SC2154,SC2034
set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
candidate_write
proposal="$orbit_root/slices/slice-demo-next.json"
jq '.id="slice-demo-next" | .basedOn.reconciliationId="reconciliation-demo-new"' "$orbit_root/slices/slice-demo-o1.json" > "$proposal"
jq -S '.criterionAssessments' "$candidate" > "$sb/status-before"
jq -S '.scope' "$proposal" > "$sb/scope-before"
at_before=$(jq -r '.reconciledAt' "$candidate")
# The PR adds its own old Snapshot. Refresh must remove only this file.
jq '.id="snapshot-demo-pr-old" | .repositories[0].repositoryId="owner/demo-widget"' "$orbit_root/snapshots/snapshot-demo-widget-1.json" > "$orbit_root/snapshots/snapshot-demo-pr-old.json"
jq '.projectSnapshotId="snapshot-demo-pr-old" | .observations += ["Snapshot observes dev merge-base 0000000000000000000000000000000000000000."]' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
# A branch update can leave the proposal on the base Reconciliation.
jq '.basedOn.reconciliationId="reconciliation-demo-widget-r1"' "$proposal" > "$proposal.t"
mv "$proposal.t" "$proposal"
g add docs
g commit -qm progress
g checkout -q base
printf 'Base update\n' > "$sb/base-file"
g add base-file
g commit -qm update
g checkout -q feature/demo
g merge -qm refresh base
expect 19 --slice slice-demo-widget-o1 --pr 42
echo 'FAIL-BEFORE refresh: the updated branch fails provenance with exit 19.'
# Extend the shared CLI mock with snapshot support.
cp "$ORBIT_BIN" "$sb/bin/orbit-original"
cat > "$ORBIT_BIN" <<'MOCK'
#!/usr/bin/env bash
if [ "$1" != snapshot ]; then exec "$(dirname "$0")/orbit-original" "$@"; fi
shift
while [ $# -gt 0 ]; do
  case "$1" in --path) path="$2" ;; --output) output="$2" ;; --repository) repo="$2" ;; esac
  shift 2
done
sha=$(git -C "$path" rev-parse HEAD)
jq -n --arg sha "$sha" --arg repo "$repo" '{specVersion:"0.1",id:("snapshot-demo-"+$sha),project:{id:"demo-widget"},observedAt:"2026-10-13T00:00:00Z",repositories:[{repositoryId:$repo,branch:"HEAD",commit:$sha}]}' > "$output"
MOCK
bash "$sb/.claude/skills/orbit/lib/refresh-slice-record.sh" --orbit-root "$orbit_root" --base base --pr 42
expect 0 --slice slice-demo-widget-o1 --pr 42
jq -S '.criterionAssessments' "$candidate" > "$sb/status-after"
jq -S '.scope' "$proposal" > "$sb/scope-after"
cmp "$sb/status-before" "$sb/status-after"
cmp "$sb/scope-before" "$sb/scope-after"
snapshot=$(jq -r '.projectSnapshotId' "$candidate")
[ "$(jq -r '.repositories[0].commit' "$orbit_root/snapshots/$snapshot.json")" = "$(g merge-base base HEAD)" ]
[ -f "$orbit_root/snapshots/snapshot-demo-widget-1.json" ]
[ ! -f "$orbit_root/snapshots/snapshot-demo-pr-old.json" ]
[ "$(jq -r '.basedOn.reconciliationId' "$proposal")" = "$(jq -r '.id' "$candidate")" ]
[ "$(jq -r '.basedOn.planRevision' "$proposal")" = "$(jq -r '.planRevision' "$candidate")" ]
[ "$(jq -r '.observations[1]' "$candidate")" = "Snapshot observes dev merge-base $(g merge-base base HEAD)." ]
[ "$(jq -r '.repositories[0].repositoryId' "$orbit_root/snapshots/$snapshot.json")" = owner/demo-widget ]
[ "$(jq -r '.reconciledAt' "$candidate")" != "$at_before" ]
echo 'PASS refresh preserves status, scope, the repository ID and the base snapshot, and updates reconciledAt.'

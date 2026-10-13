#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
widget_slice="$orbit_root/slices/slice-demo-o1.json"
# Slice A owns ac-X. Its record is on the base branch before any build starts.
g checkout -q dev
jq '.id="slice-demo-a-o1" | .contributesTo=["ac-X"]' "$widget_slice" > "$orbit_root/slices/slice-demo-a-o1.json"
g add docs
g commit -qm 'Slice A record'
g branch -f base
g checkout -q feature/demo
sha=$(g merge-base base HEAD)
candidate_write
expect 0 --slice slice-demo-widget-o1 --pr 42

# Branch A advances ac-X while branch B keeps its old record.
g checkout -qb feature/A base
sha=$(g rev-parse base)
candidate_write
jq '.criterionAssessments[1].status="achieved" | .criterionAssessments[1].evidence=["tests/proof.sh"] | .observations |= map(sub("#42;"; "#41;"))' "$candidate" > "$sb/a.t"
mv "$sb/a.t" "$candidate"
mkdir -p "$sb/tests"
echo '# Proof.' > "$sb/tests/proof.sh"
g add tests
expect 0 --slice slice-demo-a-o1 --pr 41
g add docs tests
g commit -qm 'Deliver A (#41)'
g branch -f base
g checkout -q feature/demo
sha=$(g merge-base base HEAD)
candidate_write
expect 17 --slice slice-demo-widget-o1 --pr 42

# A PR cannot widen its own scope: the lint reads the slice from the base branch.
jq '.contributesTo += ["ac-X"]' "$widget_slice" > "$widget_slice.t"
mv "$widget_slice.t" "$widget_slice"
expect 17 --slice slice-demo-widget-o1 --pr 42
g checkout -q -- docs/orbit/slices

# Preserve A when B updates its record.
jq '.criterionAssessments[1].status="achieved"' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
expect 0 --slice slice-demo-widget-o1 --pr 42

# A slice ID with no record on the base branch fails.
expect 17 --slice slice-demo-missing-o1 --pr 42

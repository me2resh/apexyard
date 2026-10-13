#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
candidate_write
expect 0 --slice slice-demo-widget-o1 --pr 42
# Branch A advances ac-X while branch B keeps its old record.
g checkout -qb feature/A base
jq '.contributesTo=["ac-X"]' "$orbit_root/slices/slice-demo-o1.json" > "$sb/slice.t"
mv "$sb/slice.t" "$orbit_root/slices/slice-demo-o1.json"
jq '.criterionAssessments[1].status="achieved" | .criterionAssessments[1].evidence=["tests/proof.sh"]' "$candidate" > "$sb/a.t"
mv "$sb/a.t" "$candidate"
mkdir -p "$sb/tests"
echo '# Proof.' > "$sb/tests/proof.sh"
g add tests

expect 0 --slice slice-demo-widget-o1 --pr 42
g add docs tests
g commit -qm 'Deliver A (#41)'
g branch -f base
g checkout -q feature/demo
candidate_write
expect 17 --slice slice-demo-widget-o1 --pr 42
# Preserve A when B updates its record.
jq '.criterionAssessments[1].status="achieved"' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
expect 0 --slice slice-demo-widget-o1 --pr 42

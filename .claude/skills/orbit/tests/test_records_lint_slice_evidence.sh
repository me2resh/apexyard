#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
candidate_write
jq '.criterionAssessments[0].status="achieved" | .criterionAssessments[0].evidence=["No proof."]' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
expect 18 --slice slice-demo-widget-o1
# A record path is not evidence, even when the PR changes it.
jq --arg p "${candidate#"$sb"/}" '.criterionAssessments[0].evidence=[($p + " records it.")]' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
g add docs
expect 18 --slice slice-demo-widget-o1
mkdir -p "$sb/tests"
echo '# Proof.' > "$sb/tests/proof.sh"
g add tests
jq '.criterionAssessments[0].evidence=["tests/proof.sh passes."]' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
expect 0 --slice slice-demo-widget-o1
jq '.criterionAssessments[0].status="contradicted" | .criterionAssessments[0].evidence=[]' "$candidate" > "$candidate.t"
mv "$candidate.t" "$candidate"
expect 0 --slice slice-demo-widget-o1
candidate_write
expect 0 --slice slice-demo-widget-o1

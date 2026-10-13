#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
candidate_write
expect 19 --slice slice-demo-widget-o1 --pr 43
sha=0000000000000000000000000000000000000000
candidate_write
expect 19 --slice slice-demo-widget-o1 --pr 42
sha=$(g rev-parse base)
candidate_write
printf '**ORBIT slice:** `slice-demo-widget-o1`\n' > "$sb/body"
expect 0 --pr-body "$sb/body" --pr 42

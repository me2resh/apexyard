#!/usr/bin/env bash
# Variables come from the caller or fixture functions.
# shellcheck disable=SC2154,SC2034

set -eu
# shellcheck source=./_lib-slice-fixtures.sh
. "$(dirname "$0")/_lib-slice-fixtures.sh"
slice_setup
out=$(expect 0 --slice slice-demo-widget-o1)
[[ "$out" == *'records-lint: WARN [progress]'* ]] || exit 1

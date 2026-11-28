#!/bin/bash
# Decision record coverage rows for /handover. Usage: coverage.sh <repo> [agdr-dir]
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
repo=${1:?usage: coverage.sh <repo> [agdr-dir]}
exec bash "$here/../../agdr/scripts/coverage-check.sh" "$repo" "${2:-$repo/docs/agdr}"

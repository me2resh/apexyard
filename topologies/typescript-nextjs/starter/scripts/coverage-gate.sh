#!/usr/bin/env bash
set -euo pipefail
floor=80
# Read the Istanbul total.lines.pct number. Missing data fails.
jq -se --argjson floor "$floor" '
  length == 1 and (.[0].total.lines.pct |
    type == "number" and . >= $floor and . <= 100)
' "${1:-coverage/coverage-summary.json}" >/dev/null

#!/usr/bin/env bash
# Report saved counters without API access.
set -euo pipefail
[ "$#" -eq 1 ] || { echo 'Usage: install-counts-report.sh INSTALL-COUNTS.jsonl' >&2; exit 2; }
jq -rs '
  sort_by(.collected_at) |
  "Release downloads (latest snapshot, cumulative)",
  "release\tdownloads\tasset_id",
  ((last.releases // [])[] |
    [.tag, (if .asset == null then "unavailable" else .asset.download_count end),
     (.asset.id // "unavailable")] | @tsv),
  "", "Tap clones per week (latest observation for each API week)",
  "week\tclones\tunique_cloners",
  ([.[] | .tap.clones[]?] | group_by(.timestamp) | .[] | last |
    [.timestamp, .count, .uniques] | @tsv),
  (if any(.[]; .tap == null) then "Tap traffic unavailable in some snapshots." else empty end)
' "$1"

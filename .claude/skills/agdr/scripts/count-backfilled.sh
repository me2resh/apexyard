#!/bin/bash
# Count explicit backfill markers in the supplied AgDR files.
set -eu
count=0
for file in "$@"; do
  if awk '
    FNR == 1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    /^---[[:space:]]*$/ { closed = 1; exit }
    /^recording:[[:space:]]*back-filled[[:space:]]*$/ { marked = 1 }
    END { exit !(closed && marked) }
  ' "$file"; then
    count=$((count + 1))
  fi
done
printf '%s\n' "$count"

#!/bin/bash
# Regression guard for duplicate AgDR identifiers in the framework decision set.
# The /agdr index keys records by the AgDR-NNNN filename prefix, so every
# committed record must own a unique identifier.

set -u

docs_dir="$(cd "$(dirname "$0")/../../../.." && pwd)/docs/agdr"
ids_file="$(mktemp)"
trap 'rm -f "$ids_file"' EXIT

find "$docs_dir" -maxdepth 1 -type f -name 'AgDR-[0-9][0-9][0-9][0-9]-*.md' -print \
  | sed -E 's#.*/(AgDR-[0-9]{4})-.*#\1#' \
  | sort > "$ids_file"

duplicates=$(uniq -d "$ids_file")
if [ -n "$duplicates" ]; then
  echo "FAIL: duplicate AgDR identifiers: $(printf '%s' "$duplicates" | tr '\n' ' ')"
  exit 1
fi

count=$(wc -l < "$ids_file" | tr -d ' ')
echo "AgDR unique-ID guard: PASS ($count identifiers)"

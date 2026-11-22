#!/bin/bash
# Match repository subjects against AgDR text. A person confirms each row.
# Usage: coverage-check.sh <repo> <agdr-dir>
# Output: kind<TAB>name<TAB>hint. Hints: title-or-chosen, body-only, unnamed.
# Whole-word, case-insensitive match. Names of 3 characters or fewer are skipped.
set -eu
repo=${1:?usage: coverage-check.sh <repo> <agdr-dir>}
dir=${2:?usage: coverage-check.sh <repo> <agdr-dir>}
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
bash "$here/list-subjects.sh" "$repo" | while IFS=$'\t' read -r kind name _src; do
  hint=unnamed
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    if grep -E -i '^(# |Chosen:)' "$f" | grep -Fiqw -- "$name"; then hint=title-or-chosen; break; fi
    if grep -Fiqw -- "$name" "$f"; then hint=body-only; fi
  done
  printf '%s\t%s\t%s\n' "$kind" "$name" "$hint"
done

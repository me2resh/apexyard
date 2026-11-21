#!/bin/bash
# List recent commits by verification evidence. No fetch or state changes.
set -euo pipefail
limit="${1:-50}"
[[ "$limit" =~ ^[1-9][0-9]*$ ]] && [ "${#limit}" -le 6 ] || {
  echo 'Usage: bash bin/verified-commits.sh [positive commit count]' >&2
  exit 2
}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../.claude/hooks/_lib-verified.sh
. "$root/.claude/hooks/_lib-verified.sh"
rows=""
while IFS= read -r sha; do
  value=$(git show -s --format=%B "$sha" | verified_value)
  row=$(git show -s --format='%h %s' "$sha")
  rows+="$value"$'\t'"$row"$'\n'
done <<< "$(git log -n "$limit" --format=%H)"
for group in e2e tests ci-only none missing invalid; do
  printf '%s:\n' "$group"
  printf '%s' "$rows" | awk -F '\t' -v g="$group" '$1 == g { sub(/^[^\t]*\t/, ""); print "  " $0 }'
done

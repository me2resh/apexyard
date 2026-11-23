#!/bin/bash
# Check that a PR links a record for each new dependency or outside host.
# Usage: check-dependency-record.sh <repo> <base-ref>
# A record is a whole-word mention in docs/agdr/*.md or docs/stack-register.md.
# Output: BLOCK or WARN lines. Exit 1 on any BLOCK, 0 otherwise, 2 on a usage error.
# A new runtime dependency or outside host with no record blocks.
# A new dev-only dependency with no record warns.
# This check is a guardrail for honest mistakes (AgDR-0320).
set -euo pipefail
repo=${1:?usage: check-dependency-record.sh <repo> <base-ref>}
base=${2:?usage: check-dependency-record.sh <repo> <base-ref>}
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
[ -d "$repo" ] || { echo "check-dependency-record.sh: no repository: $repo" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/base"
if ! git -C "$repo" archive "$base" 2>/dev/null | tar -x -C "$tmp/base" 2>/dev/null; then
  echo "check-dependency-record.sh: cannot read base ref: $base" >&2
  exit 2
fi
bash "$here/list-subjects.sh" "$tmp/base" | cut -f1,2 | sort -u > "$tmp/old"
bash "$here/list-subjects.sh" "$repo" | cut -f1,2 | sort -u > "$tmp/new"
# A name is a whole word when no name character touches it. - . / _ @ are name characters.
recorded() {
  esc=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
  pre='(^|[^A-Za-z0-9_.@/-])'
  post='([^A-Za-z0-9_@/-]|\.([^A-Za-z0-9]|$)|$)'
  for f in "$repo"/docs/agdr/*.md "$repo/docs/stack-register.md"; do
    [ -f "$f" ] || continue
    if grep -Eiq -- "$pre$esc$post" "$f"; then return 0; fi
  done
  return 1
}
rc=0
while IFS=$'\t' read -r kind name; do
  [ -n "$name" ] || continue
  grep -Fxq -- "$kind	$name" "$tmp/old" && continue
  recorded "$name" && continue
  if [ "$kind" = dev ]; then
    echo "WARN	$kind	$name	no AgDR or stack-register line"
  else
    echo "BLOCK	$kind	$name	no AgDR or stack-register line"
    rc=1
  fi
done < "$tmp/new"
exit $rc

#!/bin/bash
# Report AgDR gaps against code. Usage: stats-gaps.sh <repo> <agdr-dir>
# Lines: proposed-in-use | superseded-in-use | test-only-runtime, then the name.
set -eu
repo=${1:?usage: stats-gaps.sh <repo> <agdr-dir>}
dir=${2:?usage: stats-gaps.sh <repo> <agdr-dir>}
here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
subjects=$(bash "$here/list-subjects.sh" "$repo")

# Files that name a subject, outside manifests and docs.
files_naming() {
  grep -rFilw --binary-files=without-match \
    --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=docs \
    --exclude='*.md' --exclude='*.lock' --exclude='package*.json' --exclude='requirements*.txt' \
    --exclude='pyproject.toml' --exclude='go.mod' --exclude='go.sum' --exclude='Gemfile*' \
    --exclude='Cargo.toml' -- "$1" "$repo" 2>/dev/null || true
}

for f in "$dir"/*.md; do
  [ -f "$f" ] || continue
  status=$(awk 'NR==1&&!/^---/{exit} /^---/{c++; if(c==2)exit} /^status:/{sub(/^status:[[:space:]]*/,""); print; exit}' "$f")
  case "$status" in proposed*) tag=proposed-in-use ;; superseded*) tag=superseded-in-use ;; *) continue ;; esac
  head=$(grep -E -i '^(# |Chosen:)' "$f" || true)
  printf '%s\n' "$subjects" | while IFS=$'\t' read -r kind name _src; do
    [ -n "$name" ] || continue
    printf '%s\n' "$head" | grep -Fiqw -- "$name" || continue
    if [ "$kind" = host ] || [ -n "$(files_naming "$name")" ]; then
      printf '%s\t%s\t%s\n' "$tag" "$name" "$(basename "$f")"
    fi
  done
done

printf '%s\n' "$subjects" | while IFS=$'\t' read -r kind name _src; do
  [ "$kind" = runtime ] || continue
  hits=$(files_naming "$name")
  [ -n "$hits" ] || continue
  if ! printf '%s\n' "$hits" | grep -Evq '(^|/)(tests?|__tests__|spec|specs)/|(\.test\.|\.spec\.|/test_|_test\.)'; then
    printf 'test-only-runtime\t%s\t-\n' "$name"
  fi
done

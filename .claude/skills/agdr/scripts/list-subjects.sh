#!/bin/bash
# List dependencies and outside hosts of a repository.
# Output: kind<TAB>name<TAB>source. Kinds: host, runtime, dev.
# Names of 3 characters or fewer are skipped.
set -eu
repo=${1:?usage: list-subjects.sh <repo>}
emit() { [ "${#2}" -gt 3 ] && printf '%s\t%s\t%s\n' "$1" "$2" "$3" || true; }

# Outside hosts first: they can be data processors.
grep -rEoh --binary-files=without-match \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor \
  --exclude-dir=docs --exclude-dir=dist --exclude-dir=target \
  --exclude='*.md' --exclude='*.lock' --exclude='package-lock.json' \
  --exclude='test_*' --exclude='*.test.*' --exclude='*.spec.*' \
  'https?://[A-Za-z0-9.-]+' "$repo" 2>/dev/null |
  sed -E 's#^https?://##' | sort -u |
  { grep -Ev '^(localhost|127\.|0\.0\.0\.0|example\.(com|org|net)$|www\.w3\.org$|json-schema\.org$|rubygems\.org$|registry\.npmjs\.org$|pypi\.org$|crates\.io$|schemas?\.)' || true; } |
  while IFS= read -r host; do emit host "$host" "code-or-config"; done

pj="$repo/package.json"
if [ -f "$pj" ]; then
  awk '
    /"(dependencies|devDependencies|peerDependencies|optionalDependencies)"[[:space:]]*:/ {
      sect = ($0 ~ /"devDependencies"/) ? "dev" : "runtime"; inblk = 1; next }
    inblk && /}/ { inblk = 0 }
    inblk && match($0, /"[^"]+"[[:space:]]*:/) {
      n = substr($0, RSTART + 1, RLENGTH - 1); sub(/".*/, "", n); print sect "\t" n "\tpackage.json" }
  ' "$pj" | while IFS=$'\t' read -r k n s; do emit "$k" "$n" "$s"; done
fi

for rq in "$repo"/requirements*.txt; do
  [ -f "$rq" ] || continue
  kind=runtime
  case "$(basename "$rq")" in *dev*|*test*) kind=dev ;; esac
  sed -E 's/#.*//; s/[[:space:]]//g; /^(-|$)/d; s/[][<>=!~;@].*//' "$rq" |
    while IFS= read -r n; do emit "$kind" "$n" "$(basename "$rq")"; done
done

if [ -f "$repo/pyproject.toml" ]; then
  awk '
    /^\[project\]/ { s = "p"; next }
    /^\[tool\.poetry\.dependencies\]/ { s = "poetry"; next }
    /^\[/ { s = ""; next }
    s == "p" && /^dependencies[[:space:]]*=/ { inarr = 1 }
    inarr { while (match($0, /"[A-Za-z0-9_.-]+/)) { print substr($0, RSTART + 1, RLENGTH - 1); $0 = substr($0, RSTART + RLENGTH) }
            if ($0 ~ /\]/) inarr = 0; next }
    s == "poetry" && match($0, /^[A-Za-z0-9_.-]+[[:space:]]*=/) { n = substr($0, 1, RLENGTH - 1); gsub(/[[:space:]]/, "", n); if (n != "python") print n }
  ' "$repo/pyproject.toml" | while IFS= read -r n; do emit runtime "$n" pyproject.toml; done
fi

if [ -f "$repo/go.mod" ]; then
  awk '
    /^require[[:space:]]*\(/ { b = 1; next }
    b && /^\)/ { b = 0 }
    b && NF { print $1 }
    /^require[[:space:]]+[^(]/ { print $2 }
  ' "$repo/go.mod" | while IFS= read -r n; do emit runtime "$n" go.mod; done
fi

if [ -f "$repo/Gemfile" ]; then
  sed -nE "s/^[[:space:]]*gem[[:space:]]+['\"]([^'\"]+)['\"].*/\1/p" "$repo/Gemfile" |
    while IFS= read -r n; do emit runtime "$n" Gemfile; done
fi

if [ -f "$repo/Cargo.toml" ]; then
  awk '
    /^\[dependencies\]/ { s = "runtime"; next }
    /^\[(dev-dependencies|build-dependencies)\]/ { s = "dev"; next }
    /^\[/ { s = ""; next }
    s != "" && match($0, /^[A-Za-z0-9_-]+[[:space:]]*=/) { n = substr($0, 1, RLENGTH - 1); gsub(/[[:space:]]/, "", n); print s "\t" n }
  ' "$repo/Cargo.toml" | while IFS=$'\t' read -r k n; do emit "$k" "$n" Cargo.toml; done
fi

#!/bin/bash
# List dependencies and outside hosts of a repository.
# Output: kind<TAB>name<TAB>source. Kinds: host, runtime, dev.
# Names of 3 characters or fewer are skipped.
# Symlinked manifests are ignored.
set -eu
repo=${1:?usage: list-subjects.sh <repo>}
if [ ! -d "$repo" ]; then
  echo "list-subjects.sh: repository path not found: $repo" >&2
  exit 2
fi
emit() { [ "${#2}" -gt 3 ] && printf '%s\t%s\t%s\n' "$1" "$2" "$3" || true; }
manifest() { [ -f "$repo/$1" ] && [ ! -L "$repo/$1" ]; }

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

if manifest package.json && command -v jq >/dev/null 2>&1; then
  jq -r '
    ((.dependencies // {}) + (.peerDependencies // {}) + (.optionalDependencies // {}) | keys[] | "runtime\t" + .),
    ((.devDependencies // {}) | keys[] | "dev\t" + .)
  ' "$repo/package.json" 2>/dev/null |
    while IFS=$'\t' read -r k n; do emit "$k" "$n" package.json; done
fi

for rq in "$repo"/requirements*.txt; do
  [ -f "$rq" ] && [ ! -L "$rq" ] || continue
  kind=runtime
  case "$(basename "$rq")" in *dev*|*test*) kind=dev ;; esac
  sed -E 's/#.*//; s/[[:space:]]//g; /^(-|$)/d; s/[][<>=!~;@].*//' "$rq" |
    while IFS= read -r n; do emit "$kind" "$n" "$(basename "$rq")"; done
done

if manifest pyproject.toml; then
  awk '
    /^\[project\]/ { s = "p"; next }
    /^\[tool\.poetry\.dependencies\]/ { s = "poetry"; next }
    /^\[/ { s = ""; next }
    s == "p" && /^dependencies[[:space:]]*=/ { inarr = 1; sub(/^dependencies[[:space:]]*=[[:space:]]*\[?/, "") }
    inarr {
      line = $0
      while (match(line, /"[A-Za-z0-9_.-]+/)) {
        print substr(line, RSTART + 1, RLENGTH - 1)
        rest = substr(line, RSTART + RLENGTH)
        sub(/^[^"]*"/, "", rest)
        line = rest
      }
      # The array ends at a closing bracket outside quoted strings.
      t = $0; gsub(/"[^"]*"/, "", t)
      if (t ~ /\]/) inarr = 0
      next
    }
    s == "poetry" && match($0, /^[A-Za-z0-9_.-]+[[:space:]]*=/) { n = substr($0, 1, RLENGTH - 1); gsub(/[[:space:]]/, "", n); if (n != "python") print n }
  ' "$repo/pyproject.toml" | while IFS= read -r n; do emit runtime "$n" pyproject.toml; done
fi

if manifest go.mod; then
  awk '
    /^require[[:space:]]*\(/ { b = 1; next }
    b && /^\)/ { b = 0 }
    /\/\/[[:space:]]*indirect/ { next }
    b && NF { print $1 }
    /^require[[:space:]]+[^(]/ { print $2 }
  ' "$repo/go.mod" | while IFS= read -r n; do emit runtime "$n" go.mod; done
fi

if manifest Gemfile; then
  awk '
    function quoted(s,   m) { if (match(s, /gem[[:space:]]+["'"'"'][^"'"'"']+["'"'"']/)) { m = substr(s, RSTART, RLENGTH); sub(/^gem[[:space:]]+["'"'"']/, "", m); sub(/["'"'"']$/, "", m); return m } return "" }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*group[[:space:]].*do[[:space:]]*$/ { depth = 1; dev = ($0 ~ /:(test|development)|"(test|development)"/); next }
    depth && /^[[:space:]]*end[[:space:]]*$/ { depth--; if (!depth) dev = 0; next }
    depth && /[[:space:]]do[[:space:]]*$/ { depth++ }
    /^[[:space:]]*gem[[:space:]]/ { n = quoted($0); if (n != "") print (dev ? "dev" : "runtime") "\t" n }
  ' "$repo/Gemfile" | while IFS=$'\t' read -r k n; do emit "$k" "$n" Gemfile; done
fi

if manifest Cargo.toml; then
  awk '
    /^\[dependencies\]/ { s = "runtime"; next }
    /^\[(dev-dependencies|build-dependencies)\]/ { s = "dev"; next }
    /^\[/ { s = ""; next }
    s != "" && match($0, /^[A-Za-z0-9_-]+[[:space:]]*=/) { n = substr($0, 1, RLENGTH - 1); gsub(/[[:space:]]/, "", n); print s "\t" n }
  ' "$repo/Cargo.toml" | while IFS=$'\t' read -r k n; do emit "$k" "$n" Cargo.toml; done
fi

#!/usr/bin/env bash
set -euo pipefail
if [ ! -f package.json ]; then
  printf '::warning::exact pins: no package.json. Pin each dependency before release.\n'
  exit 0
fi
bad=$(jq -r '
  [.dependencies, .devDependencies, .optionalDependencies]
  | map(select(type == "object"))
  | add // {}
  | to_entries[]
  | select((.value | type) != "string" or (.value | test("^[0-9]+\\.[0-9]+\\.[0-9]+([-+][0-9A-Za-z.-]+)?$") | not))
  | .key + " " + (.value | tostring)
' package.json)
if [ -n "$bad" ]; then
  printf 'exact pins: use an exact version\n%s\n' "$bad" >&2
  exit 1
fi

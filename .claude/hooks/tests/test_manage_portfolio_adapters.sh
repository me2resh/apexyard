#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/workspace/ok"
cat > "$TMP/registry.yaml" <<YAML
version: 1
projects:
  - name: ok
    workspace: workspace/ok
    adapters: []
  - name: missing
    workspace: workspace/missing
    adapters: [codex]
YAML
if "$ROOT/bin/manage-portfolio-adapters.sh" --check --registry "$TMP/registry.yaml" >"$TMP/out" 2>&1; then
  echo "expected drift check to fail" >&2; exit 1
fi
grep -q 'DRIFT missing: workspace missing' "$TMP/out"
"$ROOT/bin/manage-portfolio-adapters.sh" --check --registry "$TMP/registry.yaml" --project ok >/dev/null
echo "PASS: portfolio adapter management"

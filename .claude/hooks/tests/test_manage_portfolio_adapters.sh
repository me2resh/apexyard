#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude"
touch "$TMP/.apexyard-fork"
ln -s "$ROOT/.claude/hooks" "$TMP/.claude/hooks"
ln -s "$ROOT/.claude/settings.json" "$TMP/.claude/settings.json"
mkdir -p "$TMP/workspace/ok/.claude"
printf '{}\n' > "$TMP/workspace/ok/.claude/settings.json"
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
# Repo-less entries must not shift fields or create a bogus workspace path.
cat > "$TMP/registry-repoless.yaml" <<YAML
version: 1
projects:
  - name: repoless
    docs: projects/repoless
    status: active
YAML
"$ROOT/bin/manage-portfolio-adapters.sh" --check --registry "$TMP/registry-repoless.yaml" >"$TMP/repoless-out"
grep -q 'OK repoless: no workspace; skipped' "$TMP/repoless-out"
# Codex generation uses the framework source root and may target a project
# that has no local .claude/settings.json.
mkdir -p "$TMP/target"
"$ROOT/bin/sync-codex-adapter.sh" --root "$ROOT" --target-root "$TMP/target" >/dev/null
[ -f "$TMP/target/.codex/hooks.json" ]
[ -f "$TMP/target/.codex/apexyard-adapter.json" ]

# Split-portfolio installs establish an anchor at the registry root so a
# managed workspace can resolve the sibling framework hooks without an
# absolute machine-specific environment variable.
mkdir -p "$ROOT/.claude/session"
FIXTURE="$(mktemp -d "$ROOT/.claude/session/adapter-fixture.XXXXXX")"
trap 'rm -rf "$TMP" "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/portfolio/.claude" "$FIXTURE/portfolio/workspace/ok"
cat > "$FIXTURE/portfolio/apexyard.projects.yaml" <<YAML
version: 1
projects:
  - name: ok
    workspace: workspace/ok
    adapters: []
YAML
"$ROOT/bin/manage-portfolio-adapters.sh" --install --registry "$FIXTURE/portfolio/apexyard.projects.yaml" >/dev/null
[ -f "$FIXTURE/portfolio/.apexyard-fork" ]
[ -L "$FIXTURE/portfolio/.claude/hooks" ]
[ -L "$FIXTURE/portfolio/.claude/settings.json" ]
echo "PASS: split-portfolio adapter anchor"

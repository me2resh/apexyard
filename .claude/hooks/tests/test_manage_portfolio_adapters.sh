#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MAIN_ROOT="$ROOT"
if common_git_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  MAIN_ROOT="$(cd "$(dirname "$common_git_dir")" && pwd)"
fi
# manage-portfolio-adapters.sh requires yq. Do not print a line that starts
# with SKIP. bin/run-hook-tests.sh treats that as a failed suite even when
# the test exits 0.
if ! command -v yq >/dev/null 2>&1; then
  echo "PASS: portfolio adapter management (yq not installed; script requires yq)"
  echo "PASS: split-portfolio adapter anchor (yq not installed; script requires yq)"
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude"
touch "$TMP/.apexyard-fork"
ln -s "$MAIN_ROOT/.claude/hooks" "$TMP/.claude/hooks"
ln -s "$MAIN_ROOT/.claude/settings.json" "$TMP/.claude/settings.json"
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
# A docs-only registry never increments count. Unsafe links must still fail.
cat > "$TMP/registry-docsonly.yaml" <<YAML
version: 1
projects:
  - name: docsonly
    docs: projects/docsonly
    status: active
YAML
unlink "$TMP/.claude/hooks"
ln -s "$TMP" "$TMP/.claude/hooks"
if "$ROOT/bin/manage-portfolio-adapters.sh" --check --registry "$TMP/registry-docsonly.yaml" >"$TMP/docsonly-out" 2>&1; then
  echo "expected unsafe hooks link with no workspace to fail" >&2
  exit 1
fi
grep -q 'unsafe hooks link target' "$TMP/docsonly-out"
unlink "$TMP/.claude/hooks"
ln -s "$MAIN_ROOT/.claude/hooks" "$TMP/.claude/hooks"
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
    adapters: [codex]
YAML
"$ROOT/bin/manage-portfolio-adapters.sh" --install --registry "$FIXTURE/portfolio/apexyard.projects.yaml" >/dev/null
[ -f "$FIXTURE/portfolio/.apexyard-fork" ]
[ -L "$FIXTURE/portfolio/.claude/hooks" ]
[ -L "$FIXTURE/portfolio/.claude/settings.json" ]
workspace="$FIXTURE/portfolio/workspace/ok"
[ -f "$workspace/.codex/hooks.json" ]
# Wave 2 (AgDR-0157) emits dispatch-bash.sh, not a per-hook command.
hook=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("dispatch-bash.sh")) | .command' "$workspace/.codex/hooks.json")
if [ -z "$hook" ]; then
  echo "expected a dispatch-bash.sh PreToolUse command in generated hooks.json" >&2
  exit 1
fi
set +e
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git add -A"}}' | (
  cd "$workspace" || exit 1
  export CLAUDE_CODE_SESSION_ID=ci-session
  export APEXYARD_OPS_PIN_DIR="$TMP/pin-dir"
  mkdir -p "$APEXYARD_OPS_PIN_DIR" "$TMP/pin-ops/.claude/hooks"
  printf '%s\n' 'exit 0' > "$TMP/pin-ops/.claude/hooks/dispatch-bash.sh"
  chmod +x "$TMP/pin-ops/.claude/hooks/dispatch-bash.sh"
  printf '%s\n' "$TMP/pin-ops" > "$APEXYARD_OPS_PIN_DIR/ops-root-ci-session"
  env -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR bash -c "$hook"
) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 2 ]; then
  echo "expected git add -A to be blocked with rc=2, got $rc" >&2
  exit 1
fi
unlink "$FIXTURE/portfolio/.claude/hooks"
ln -s "$TMP" "$FIXTURE/portfolio/.claude/hooks"
if "$ROOT/bin/manage-portfolio-adapters.sh" --check --registry "$FIXTURE/portfolio/apexyard.projects.yaml" >"$TMP/unsafe-out" 2>&1; then
  echo "expected unsafe hook link to fail drift check" >&2
  exit 1
fi
grep -q 'unsafe hooks link target' "$TMP/unsafe-out"
echo "PASS: split-portfolio adapter anchor"

#!/usr/bin/env bash
# Install and audit declared ApexYard harness adapters across registered projects.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Use the main checkout as the durable ops-root anchor when this command runs
# from a linked worktree. Generated adapters may be temporary, but the anchor
# must not point at a worktree that is removed after the PR merges.
FRAMEWORK_ANCHOR_ROOT="$FRAMEWORK_ROOT"
if common_git_dir=$(git -C "$FRAMEWORK_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  FRAMEWORK_ANCHOR_ROOT="$(cd "$(dirname "$common_git_dir")" && pwd)"
fi
REGISTRY=""
MODE=check
PROJECT_FILTER=""
usage(){ cat <<USAGE
Usage: bin/manage-portfolio-adapters.sh [--install|--check] [--registry PATH] [--project NAME]

Reads each project's adapters list from the portfolio registry. Supported adapters:
claude, codex, pi, opencode, cursor. --check is read-only and reports drift.
USAGE
}
while [ "$#" -gt 0 ]; do case "$1" in
  --install) MODE=install;; --check) MODE=check;;
  --registry) REGISTRY="$2"; shift;; --project) PROJECT_FILTER="$2"; shift;;
  -h|--help) usage; exit 0;; *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2;; esac; shift; done
if [ -z "$REGISTRY" ]; then
  source "$FRAMEWORK_ROOT/.claude/hooks/_lib-read-config.sh"
  source "$FRAMEWORK_ROOT/.claude/hooks/_lib-portfolio-paths.sh"
  REGISTRY="$(portfolio_registry)"
fi
[ -f "$REGISTRY" ] || { echo "ERROR: registry not found: $REGISTRY" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "ERROR: yq is required" >&2; exit 1; }
root_dir="$(cd "$(dirname "$REGISTRY")" && pwd)"
count=0; drift=0
if [ "$root_dir" != "$FRAMEWORK_ROOT" ]; then
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required to create relative portfolio adapter links" >&2
    exit 1
  }
fi

link_resolves_to() {
  python3 - "$1" "$2" <<'PY'
import os, sys
print("true" if os.path.realpath(sys.argv[1]) == os.path.realpath(sys.argv[2]) else "false")
PY
}

ensure_split_portfolio_anchor() {
  [ "$root_dir" = "$FRAMEWORK_ROOT" ] && return 0
  local anchor="$root_dir/.apexyard-fork"
  local config_dir="$root_dir/.claude"
  local hooks_link="$config_dir/hooks"
  local settings_link="$config_dir/settings.json"
  if [ "$MODE" = install ]; then
    [ -e "$anchor" ] || : > "$anchor"
    mkdir -p "$config_dir"
    if [ ! -e "$hooks_link" ] && [ ! -L "$hooks_link" ]; then
      local hooks_target settings_target
      hooks_target=$(python3 - "$config_dir" "$FRAMEWORK_ANCHOR_ROOT/.claude/hooks" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)
      ln -s "$hooks_target" "$hooks_link"
    fi
    if [ ! -e "$settings_link" ] && [ ! -L "$settings_link" ]; then
      local settings_target
      settings_target=$(python3 - "$config_dir" "$FRAMEWORK_ANCHOR_ROOT/.claude/settings.json" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
)
      ln -s "$settings_target" "$settings_link"
    fi
  fi
  [ -f "$anchor" ] || { echo "DRIFT portfolio: missing $anchor (run --install to create it)"; return 1; }
  [ -L "$hooks_link" ] && [ -d "$hooks_link" ] || { echo "DRIFT portfolio: $hooks_link must link to framework hooks"; return 1; }
  [ "$(link_resolves_to "$hooks_link" "$FRAMEWORK_ANCHOR_ROOT/.claude/hooks")" = true ] || { echo "DRIFT portfolio: unsafe hooks link target"; return 1; }
  [ -L "$settings_link" ] && [ -f "$settings_link" ] || { echo "DRIFT portfolio: $settings_link must link to framework settings"; return 1; }
  [ "$(link_resolves_to "$settings_link" "$FRAMEWORK_ANCHOR_ROOT/.claude/settings.json")" = true ] || { echo "DRIFT portfolio: unsafe settings link target"; return 1; }
}

if ! ensure_split_portfolio_anchor; then
  if [ "$MODE" = check ]; then
    drift=$((drift + 1))
  else
    echo "ERROR: unable to establish the split-portfolio ops-root anchor" >&2
    exit 1
  fi
fi

while IFS= read -r row; do
  name=$(jq -r '.[0]' <<<"$row")
  workspace=$(jq -r '.[1]' <<<"$row")
  adapters=$(jq -r '.[2]' <<<"$row")
  [ -n "$name" ] || continue
  [ -z "$PROJECT_FILTER" ] || [ "$name" = "$PROJECT_FILTER" ] || continue
  [ -n "$workspace" ] || { echo "OK $name: no workspace; skipped"; continue; }
  count=$((count+1))
  case "$workspace" in /*|*".."*) echo "DRIFT $name: unsafe workspace path ($workspace)"; drift=$((drift+1)); continue;; esac
  project_root="$root_dir/$workspace"
  if [ ! -d "$project_root" ]; then echo "DRIFT $name: workspace missing ($project_root)"; drift=$((drift+1)); continue; fi
  IFS=',' read -r -a requested <<< "$adapters"
  [ -n "$adapters" ] || { echo "OK $name: adapters opted out"; continue; }
  for adapter in "${requested[@]}"; do
    case "$adapter" in
      claude) [ -d "$project_root/.claude" ] && result=ok || result=missing;;
      codex)
        if [ "$MODE" = install ]; then bash "$FRAMEWORK_ROOT/bin/sync-codex-adapter.sh" --root "$FRAMEWORK_ROOT" --target-root "$project_root" >/dev/null; result=installed
        elif { [ -f "$project_root/.codex/apexyard-adapter.json" ] || { [ -d "$project_root/.agents/skills" ] && [ -d "$project_root/.codex/agents" ] && [ -f "$project_root/.codex/hooks.json" ]; }; } && bash "$FRAMEWORK_ROOT/bin/sync-codex-adapter.sh" --root "$FRAMEWORK_ROOT" --target-root "$project_root" --check-installed >/dev/null 2>&1; then result=ok
        elif [ -e "$project_root/.codex" ] || [ -e "$project_root/.agents" ]; then result=drift; else result=missing; fi;;
      pi)
        [ ! -L "$project_root/.pi" ] && [ ! -L "$project_root/.pi/extensions" ] || { echo "DRIFT $name: pi adapter path is a symlink"; drift=$((drift+1)); continue; }
        script="$FRAMEWORK_ROOT/bin/install-pi-adapter.sh"; target="$project_root/.pi/extensions"; if [ "$MODE" = install ]; then bash "$script" --root "$FRAMEWORK_ROOT" --target-dir "$target" >/dev/null; result=installed; elif [ -f "$target/apexyard/index.ts" ]; then result=ok; else result=missing; fi;;
      opencode)
        [ ! -L "$project_root/.opencode" ] && [ ! -L "$project_root/.opencode/plugins" ] || { echo "DRIFT $name: opencode adapter path is a symlink"; drift=$((drift+1)); continue; }
        script="$FRAMEWORK_ROOT/bin/install-opencode-adapter.sh"; target="$project_root/.opencode/plugins"; if [ "$MODE" = install ]; then bash "$script" --root "$FRAMEWORK_ROOT" --target-dir "$target" >/dev/null; result=installed; elif [ -f "$target/apexyard/index.ts" ]; then result=ok; else result=missing; fi;;
      cursor)
        if [ "$MODE" = install ]; then
          bash "$FRAMEWORK_ROOT/bin/install-cursor-adapter.sh" --root "$FRAMEWORK_ROOT" >/dev/null
          result=installed
        elif [ -f "$HOME/.cursor/hooks.json" ] && grep -q 'cursor-session-pin.sh' "$HOME/.cursor/hooks.json"; then
          if grep -q 'APEXYARD_CURSOR_HOOK_GLOB' "$HOME/.cursor/hooks.json"; then result=stale; else result=ok; fi
        else
          result=missing
        fi;;
      *) echo "DRIFT $name: unsupported adapter '$adapter'"; drift=$((drift+1)); continue;;
    esac
    if [ "$result" = ok ] || [ "$result" = installed ]; then echo "$result $name: $adapter"; else echo "DRIFT $name: $adapter ($result)"; drift=$((drift+1)); fi
  done
done < <(yq -o=json -I=0 '.projects[] | [ .name, (.workspace // ""), ((.adapters // ["codex", "pi", "opencode", "cursor"]) | join(",")) ]' "$REGISTRY")
if [ "$MODE" = check ] && [ "$drift" -gt 0 ]; then echo "Portfolio adapter drift: $drift finding(s)."; exit 1; fi
[ "$count" -gt 0 ] || { echo "No registered projects matched."; exit 0; }
echo "Portfolio adapter check complete: $count project(s)."

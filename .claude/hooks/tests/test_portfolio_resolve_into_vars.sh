#!/bin/bash
# portfolio_resolve_into_vars fills _PP_WS and _PP_REG in the current shell.
# It must agree with portfolio_workspace_dir and portfolio_registry in single
# fork and split-portfolio mode, compute the fingerprint once per process,
# and never read the workspace or registry path from the environment.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"

export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

B=$(mktemp -d)
B=$(cd -P "$B" && pwd)
trap 'rm -rf "$B"' EXIT

mkfork() {
  local dir="$1"
  git init -q -b main "$dir" 2>/dev/null || git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/.apexyard-fork"
  mkdir -p "$dir/.claude"
  cp "$SRC_ROOT/.claude/project-config.defaults.json" "$dir/.claude/project-config.defaults.json"
}

# run_in <dir> <script>: runs a clean bash in <dir> that sources the libs
run_in() {
  local dir="$1" script="$2"
  env -i HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
    bash -c "cd '$dir' && . '$HOOKS/_lib-read-config.sh' && . '$HOOKS/_lib-portfolio-paths.sh' && $script" 2>&1
}

# Single fork mode
S="$B/single"
mkfork "$S"
out=$(run_in "$S" 'portfolio_resolve_into_vars; portfolio_resolve_registry_into_var; printf "%s|%s|%s|%s\n" "$_PP_WS" "$_PP_REG" "$(portfolio_workspace_dir)" "$(portfolio_registry)"')
IFS='|' read -r ws reg ws2 reg2 <<< "$out"
if [ -n "$ws" ] && [ "$ws" = "$ws2" ] && [ -n "$reg" ] && [ "$reg" = "$reg2" ]; then ok "single fork: in-process values equal the command values"; else bad "single fork" "$out"; fi
case "$ws" in "$S"/workspace) ok "single fork: workspace dir is under the fork" ;; *) bad "single fork workspace" "$ws" ;; esac

# Split-portfolio mode
P="$B/private"
mkdir -p "$P/workspace"
M="$B/split"
mkfork "$M"
printf '{"portfolio":{"registry":"%s/apexyard.projects.yaml","workspace_dir":"%s/workspace"}}\n' "$P" "$P" > "$M/.claude/project-config.json"
out=$(run_in "$M" 'portfolio_resolve_into_vars; portfolio_resolve_registry_into_var; printf "%s|%s|%s|%s\n" "$_PP_WS" "$_PP_REG" "$(portfolio_workspace_dir)" "$(portfolio_registry)"')
IFS='|' read -r ws reg ws2 reg2 <<< "$out"
if [ "$ws" = "$P/workspace" ] && [ "$ws" = "$ws2" ] && [ "$reg" = "$P/apexyard.projects.yaml" ] && [ "$reg" = "$reg2" ]; then ok "split mode: in-process values equal the command values"; else bad "split mode" "$out"; fi

# The registry is resolved on demand, never by the workspace resolution alone
out=$(run_in "$S" 'portfolio_resolve_into_vars; printf "[%s]" "$_PP_REG"; portfolio_resolve_registry_into_var; printf "[%s]" "$_PP_REG"')
if [ "$out" = "[][$S/apexyard.projects.yaml]" ]; then ok "registry path is resolved only on demand"; else bad "registry on demand" "$out"; fi

# The environment never supplies the paths
out=$(env -i HOME="$HOME" PATH="$PATH" APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1 \
  WORKSPACE_DIR=/evil PORTFOLIO_WORKSPACE_DIR=/evil PORTFOLIO_REGISTRY=/evil _PP_WS=/evil _PP_REG=/evil _PP_FP=forged \
  bash -c "cd '$S' && . '$HOOKS/_lib-read-config.sh' && . '$HOOKS/_lib-portfolio-paths.sh' && portfolio_resolve_into_vars; portfolio_resolve_registry_into_var; printf '%s|%s' \"\$_PP_WS\" \"\$_PP_REG\"" 2>&1)
case "$out" in
  *evil*) bad "environment is not trusted" "$out" ;;
  "$S/workspace|$S/apexyard.projects.yaml") ok "environment is not trusted" ;;
  *) bad "environment is not trusted" "$out" ;;
esac

# The fingerprint is computed once per process, also across re-sourcing
out=$(run_in "$S" '
  : > "'"$B"'/fpcount"
  _resolution_cache_current_fingerprint() { echo x >> "'"$B"'/fpcount"; printf UNKNOWN; }
  portfolio_resolve_into_vars
  first=$(wc -l < "'"$B"'/fpcount")
  portfolio_resolve_into_vars
  . "'"$HOOKS"'/_lib-portfolio-paths.sh"
  portfolio_resolve_into_vars
  printf "%s,%s" "${first//[[:space:]]/}" "$(wc -l < "'"$B"'/fpcount" | tr -d "[:space:]")"')
case "$out" in [1-9]*,*) a="${out%,*}"; b="${out#*,}"; [ "$a" = "$b" ] && ok "fingerprint is computed once per process" || bad "fingerprint count" "$out" ;; *) bad "fingerprint count" "$out" ;; esac

# _portfolio_reset_caches clears the state
out=$(run_in "$S" 'portfolio_resolve_into_vars; _portfolio_reset_caches; printf "[%s][%s][%s]" "$_PP_WS" "$_PP_REG" "$_PP_FP"')
if [ "$out" = "[][][]" ]; then ok "_portfolio_reset_caches clears the in-process outputs"; else bad "reset" "$out"; fi

# The per-process caches survive a re-source and a child bash starts fresh
out=$(run_in "$S" '
  portfolio_registry >/dev/null
  _PORTFOLIO_REGISTRY_CACHE=cached
  . "'"$HOOKS"'/_lib-portfolio-paths.sh"
  printf "%s|" "$_PORTFOLIO_REGISTRY_CACHE"
  bash -c ". \"'"$HOOKS"'/_lib-read-config.sh\"; . \"'"$HOOKS"'/_lib-portfolio-paths.sh\"; printf %s \"[\$_PORTFOLIO_REGISTRY_CACHE]\"" ')
if [ "$out" = "cached|[]" ]; then ok "caches survive a re-source and reset in a child shell"; else bad "re-source" "$out"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# Read-only environment report. Do not execute the suggested fixes.
# Bash 3.2; jq is optional for this report.
set -u
export APEXYARD_DISABLE_RESOLUTION_CACHE=1 APEXYARD_OPS_DISABLE_PIN=1
unset CLAUDE_CODE_SESSION_ID
result=0
report() {
  local level="$1" name="$2" detail="$3" fix="${4:-}"
  printf '%s %s: %s\n' "$level" "$name" "$detail"
  case "$level" in
    WARN) [ "$result" -ge 1 ] || result=1 ;;
    FAIL) result=2 ;;
  esac
  case "$level" in WARN|FAIL) printf '  Fix: %s\n' "$fix" ;; esac
}
if [ "$#" -ne 0 ]; then
  report FAIL arguments 'No arguments are supported.' 'Run apexyard doctor.'
  exit "$result"
fi
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
lib="$script_dir/../../hooks"
# shellcheck source=/dev/null
. "$lib/_lib-ops-root.sh"
# Normalize Git's root output before the shared detector walks the file system.
# Keep this wrapper in a subshell so later checks can show the raw Git form.
# shellcheck source=/dev/null
. "$lib/_lib-path-resolve.sh"
root=$(
  git() {
    local output rc=0
    output=$(command git "$@") || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    if [ "$*" = 'rev-parse --show-toplevel' ]; then
      if command -v cygpath >/dev/null 2>&1; then
        output=$(cygpath -u "$output" 2>/dev/null) || return 1
      fi
      _windows_path_to_posix "$output"
    else
      printf '%s\n' "$output"
    fi
  }
  resolve_ops_root_walk "$PWD"
)
if [ -n "$root" ]; then
  root=$(cd "$root" && pwd -P)
  report OK fork "$root"
else
  report FAIL fork 'No .apexyard-fork or legacy anchor found.' 'Run from the fork root.'
fi
for tool in git bash jq gh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    case "$tool" in
      git) report FAIL git missing 'Install Git for Windows, or run brew install git / apt-get install git.' ;;
      bash) report FAIL bash missing 'Install Bash 3.2 or later with brew install bash / apt-get install bash / Git for Windows.' ;;
      jq) report FAIL jq missing 'Run brew install jq / apt-get install jq / winget install jqlang.jq.' ;;
      gh) report WARN gh missing 'Run brew install gh / apt-get install gh / winget install GitHub.cli.' ;;
    esac
    continue
  fi
  version=$("$tool" --version 2>/dev/null | head -n 1)
  case "$tool" in
    git|gh) report INFO "$tool" "$version (no minimum version set)" ;;
    bash|jq)
      numbers=$(printf '%s\n' "$version" | sed -n 's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')
      major=${numbers%% *}; minor=${numbers#* }
      floor_major=3; floor_minor=2
      [ "$tool" != jq ] || { floor_major=1; floor_minor=6; }
      if [ -n "$numbers" ] && { [ "$major" -gt "$floor_major" ] || { [ "$major" -eq "$floor_major" ] && [ "$minor" -ge "$floor_minor" ]; }; }; then
        report OK "$tool" "$version"
      else
        report FAIL "$tool" "Unsupported version: $version" "Install $tool $floor_major.$floor_minor or later (brew / apt-get; Windows: Git for Windows for Bash, winget install jqlang.jq for jq)."
      fi ;;
  esac
done
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    report OK gh-auth 'Logged in with an active account.'
  else
    report WARN gh-auth 'No usable active account.' 'Run gh auth login.'
  fi
fi
[ -n "$root" ] || exit "$result"
cd "$root" || exit 2
upstream=$(git remote get-url upstream 2>/dev/null || true)
case "$upstream" in
  https://github.com/me2resh/apexyard|https://github.com/me2resh/apexyard.git|git@github.com:me2resh/apexyard|git@github.com:me2resh/apexyard.git|ssh://git@github.com/me2resh/apexyard|ssh://git@github.com/me2resh/apexyard.git)
    report OK upstream "$upstream" ;;
  *)
    fix='Run git remote add upstream https://github.com/me2resh/apexyard.git.'
    [ -z "$upstream" ] || fix='Run git remote set-url upstream https://github.com/me2resh/apexyard.git.'
    report WARN upstream "Missing or unexpected remote: $upstream" "$fix" ;;
esac
# Reuse the SessionStart detector, including mount-aware path resolution.
# shellcheck source=/dev/null
. "$lib/_lib-git-hooks-path.sh"
state=$(ghp_classify "$root" .githooks)
if [ "$state" = correct ]; then
  report OK hooksPath "Points to this clone's .githooks."
else
  report WARN hooksPath "$state" 'Run bash bin/install-git-hooks.sh.'
fi
jq_ready=0
if command -v jq >/dev/null 2>&1 && jq -n 'true' >/dev/null 2>&1; then jq_ready=1; fi
if [ "$jq_ready" -eq 1 ]; then
  # shellcheck source=/dev/null
  . "$lib/_lib-read-config.sh"
  # shellcheck source=/dev/null
  . "$lib/_lib-portfolio-paths.sh"
  # Fix the context to this fork, including linked worktrees.
  _CONFIG_ROOT_CACHE="$root"; _CONFIG_ROOT_CACHE_SET=1
  _PORTFOLIO_ROOT_CACHE="$root"
  config_ok=1
  if [ -f .claude/project-config.json ] && ! jq -e 'type == "object"' .claude/project-config.json >/dev/null 2>&1; then
    report FAIL portfolio-config 'Invalid .claude/project-config.json.' 'Correct the JSON object in .claude/project-config.json.'
    config_ok=0
  fi
  if [ "$config_ok" -eq 1 ]; then
    registry=$(portfolio_registry)
    projects=$(portfolio_projects_dir)
    workspace=$(portfolio_workspace_dir)
    case "$registry|$projects|$workspace" in
      *"$root/../"*) split=1 ;;
      *) split=0
         for path in "$registry" "$projects" "$workspace"; do
           portfolio_path_under "$path" "$root" || split=1
         done ;;
    esac
    if [ ! -f .claude/project-config.json ] && {
      [ "$split" -eq 1 ] || { [ -f .apexyard-fork ] && [ ! -f "$registry" ]; }
    }; then
      report WARN portfolio-config 'No local config for split or missing registry paths.' 'Run /setup to set the sibling portfolio paths.'
    fi
    if detail=$(portfolio_validate 2>&1); then
      report OK portfolio "registry=$registry; projects_dir=$projects; workspace_dir=$workspace"
    else
      report FAIL portfolio "$detail" 'Correct the named portfolio key and path in .claude/project-config.json.'
    fi
  fi
  # shellcheck source=/dev/null
  . "$lib/_lib-fresh-fork.sh"
  report INFO onboarding "$(fresh_fork_state); run /onboard or /setup if unconfigured."
else
  report INFO portfolio 'Skipped: jq unavailable; portfolio and onboarding checks need jq.'
fi
# Map one path to a POSIX form. Use cygpath -u when it exists.
# Otherwise map a leading X:/ or X:\ to /x/.
normalize_check_path() {
  local p="$1" converted="" drive rest
  [ -n "$p" ] || return 0
  if command -v cygpath >/dev/null 2>&1; then
    converted=$(cygpath -u -- "$p" 2>/dev/null) || converted=""
    case "$converted" in
      /*)
        printf '%s' "$converted"
        return 0
        ;;
    esac
  fi
  case "$p" in
    [A-Za-z]:/*|[A-Za-z]:\\*)
      drive=$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')
      rest=$(printf '%s' "${p#*:}" | tr '\\' '/')
      printf '/%s%s' "$drive" "$rest"
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}
# Stop a probe when it has no process group. Stop children before the parent.
stop_probe_tree() {
  local pid="$1" child
  [ -n "${pid:-}" ] || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for child in $(pgrep -P "$pid" 2>/dev/null || true); do
      stop_probe_tree "$child"
    done
  fi
  kill "$pid" 2>/dev/null || true
}
system=$(uname -s)
case "$system" in
  MINGW*|MSYS*|CYGWIN*)
    report INFO shell "$system"
    if command -v cygpath >/dev/null 2>&1; then
      git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
      shell_root=$(pwd -P)
      git_norm=$(normalize_check_path "$git_root")
      shell_norm=$(normalize_check_path "$shell_root")
      native=$(cygpath -m -- "$shell_root" 2>/dev/null || true)
      if [ "$git_norm" != "$shell_norm" ]; then
        report WARN windows-paths "shell=$shell_root; git=$git_root; normalized=$git_norm; native=$native" 'Review https://github.com/me2resh/apexyard/issues/1743 and use cygpath -u to compare mount paths.'
      else
        report OK windows-paths "shell=$shell_root; git=$git_root; native=$native"
      fi
    else
      report WARN cygpath missing 'Reinstall Git for Windows.'
    fi
    report INFO msys-path-conversion 'For git rev:path arguments, prefix the command with MSYS_NO_PATHCONV=1.'
    crlf=0
    while IFS= read -r -d '' file; do
      if [ -f "$file" ] && LC_ALL=C grep -q "$(printf '\r')$" "$file"; then
        report INFO crlf-file "$file"
        crlf=1
      fi
    done < <(git ls-files -z -- '*.sh')
    autocrlf=$(git config --get core.autocrlf 2>/dev/null || true)
    if [ "$crlf" -eq 1 ] || [ "$autocrlf" = true ]; then
      report WARN crlf "Tracked shell CRLF=$crlf; core.autocrlf=$autocrlf" 'Run git config core.autocrlf input, then check out the shell files again after saving local changes.'
    else report OK crlf 'No tracked shell CRLF or core.autocrlf=true.'; fi
    ;;
esac
if [ "$jq_ready" -eq 0 ]; then
  report INFO dispatcher 'Skipped: jq unavailable; settings and timing checks need jq.'
else
  filter='[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("dispatch-bash.sh"))]'
  settings=.claude/settings.json
  if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1; then
    report WARN dispatcher-settings "Cannot parse $settings" 'Restore valid JSON in .claude/settings.json.'
  else
    timeout=$(jq -r "$filter | .[0].timeout // empty" "$settings")
    report INFO dispatcher-timeout "Tracked timeout: ${timeout:-not set} seconds."
    for settings in .claude/settings.local.json "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
      [ -f "$settings" ] || continue
      if ! count=$(jq -er "$filter | length" "$settings" 2>/dev/null); then
        report WARN dispatcher-settings "Cannot parse $settings" "Correct the JSON object in $settings."
      elif [ "$count" -gt 0 ]; then
        report WARN dispatcher-duplicate "$count extra dispatcher entries in $settings; arrays merge, not replace." "Remove the duplicate dispatcher entry from $settings."
      fi
    done
    case "$timeout" in
      '') report INFO dispatcher-timing 'Skipped: no explicit tracked dispatcher timeout.' ;;
      *[!0-9]*|0)
      report WARN dispatcher-timeout "Invalid timeout: $timeout" 'Set a positive dispatcher timeout in tracked .claude/settings.json.' ;;
      *)
        # A ':' payload takes only the read-only paths through the gates.
        # Do not execute the configurable settings command.
        payload=$(jq -nc --arg cwd "$root" '{tool_name:"Bash",tool_input:{command:":"},cwd:$cwd}')
        start=$SECONDS
        # Own process group: a timeout must stop the dispatcher and its children.
        rc=$(
          set -m
          bash "$lib/dispatch-bash.sh" <<<"$payload" >/dev/null 2>&1 &
          dispatcher_pid=$!
          (
            trap 'kill "${sleeper:-}" 2>/dev/null || true; exit 0' TERM
            sleep "$timeout" &
            sleeper=$!
            wait "$sleeper" 2>/dev/null || true
            if ! kill -- -"$dispatcher_pid" 2>/dev/null; then
              stop_probe_tree "$dispatcher_pid"
            fi
          ) >/dev/null 2>&1 &
          watchdog_pid=$!
          probe_rc=0
          wait "$dispatcher_pid" >/dev/null 2>&1 || probe_rc=$?
          kill "$watchdog_pid" 2>/dev/null || true
          wait "$watchdog_pid" >/dev/null 2>&1 || true
          printf '%s' "$probe_rc"
        ) 2>/dev/null || true
        case "${rc:-}" in
          ''|*[!0-9]*) rc=1 ;;
        esac
        elapsed=$((SECONDS - start))
        if [ "$rc" -ne 0 ] || [ "$((elapsed * 100))" -ge "$((timeout * 80))" ]; then
          report WARN dispatcher-timing "Trivial run: ${elapsed}s / ${timeout}s; exit=$rc." 'Split long commands into shorter calls; report slow dispatch at https://github.com/me2resh/apexyard/issues/1547. No supported local timeout override exists.'
        else report OK dispatcher-timing "Trivial run: ${elapsed}s / ${timeout}s (one-second resolution)."; fi ;;
    esac
  fi
fi
exit "$result"

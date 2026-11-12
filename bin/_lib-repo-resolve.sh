#!/usr/bin/env bash
# Resolve a registered repository without changing it.
# Sets resolved_repo and resolved_clone in the caller.
# shellcheck disable=SC2034
repo_resolve() {
  local root=$1 selector=$2 current=$3 json=$4 parsed name repo ws rest origin top
  local choice index=0 selected=""
  # shellcheck source=/dev/null
  source "$root/.claude/hooks/_lib-read-config.sh"
  # shellcheck source=/dev/null
  source "$root/.claude/hooks/_lib-portfolio-paths.sh"
  # shellcheck source=/dev/null
  source "$root/.claude/hooks/_lib-multi-repo-trace.sh"
  parsed=$(cd "$root" && _mrt_parse_registry) || return 2
  origin=$(git -C "$current" remote get-url origin 2>/dev/null) || origin=""
  origin=${origin%.git}
  case "$origin" in
    *://*) origin=${origin#*://}; origin=${origin#*/} ;;
    *@*:*) origin=${origin#*:} ;;
  esac
  if [ -z "$selector" ]; then
    while IFS='|' read -r name repo ws rest; do
      if [ -n "$repo" ] && [ "$repo" = "$origin" ]; then selector=$repo; break; fi
    done <<< "$parsed"
  fi
  if [ -z "$selector" ]; then
    top=$(git -C "$current" rev-parse --show-toplevel 2>/dev/null) || top=""
    # Compare physical paths. The ops root may come from a symlinked path.
    [ -z "$top" ] || top=$(cd "$top" && pwd -P)
    if [ -n "$top" ] && [ "$top" = "$(cd "$root" && pwd -P)" ]; then
      echo 'Select a registered project:' >&2
      while IFS='|' read -r name repo ws rest; do
        [ -n "$repo" ] || continue
        index=$((index + 1))
        printf '%s) %s (%s)\n' "$index" "$name" "$repo" >&2
      done <<< "$parsed"
      [ "$json" = 0 ] && [ -t 0 ] && [ "$index" -gt 0 ] || return 2
      printf 'Project number: ' >&2
      IFS= read -r choice || return 2
      index=0
      while IFS='|' read -r name repo ws rest; do
        [ -n "$repo" ] || continue
        index=$((index + 1))
        if [ "$choice" = "$index" ]; then selected=$repo; break; fi
      done <<< "$parsed"
      [ -n "$selected" ] || { echo 'Invalid project number.' >&2; return 2; }
      selector=$selected
    else
      echo 'apexyard: no repo found. Use --repo <name|owner/name>.' >&2
      return 2
    fi
  fi
  while IFS='|' read -r name repo ws rest; do
    [ -n "$repo" ] || continue
    if [ "$selector" = "$name" ] || [ "$selector" = "$repo" ]; then
      resolved_repo=$repo
      ws=${ws:-workspace/$name}
      case "$ws" in
        /*) resolved_clone=$ws ;;
        *) resolved_clone="$(cd "$root" && dirname "$(portfolio_registry)")/$ws" ;;
      esac
      return 0
    fi
  done <<< "$parsed"
  printf '%s is not in the registry. Register it with /handover first.\n' "$selector" >&2
  return 2
}

# One adapter table supplies validation and launch argument style.
repo_agent_style() {
  case "$1" in
    claude) echo slash ;;
    codex|cursor-agent|pi) echo plain ;;
    opencode) echo opencode ;;
    *) echo 'Supported agents: claude, codex, cursor-agent, opencode, pi' >&2; return 2 ;;
  esac
}

repo_json_string() {
  local value=$1
  # Drop control characters other than tab, newline and CR. JSON forbids them raw.
  value=$(printf '%sx' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
  value=${value%x}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}

#!/bin/bash
# config_guard SETTING BASELINE_JSON CANDIDATE_JSON paths|excludes|mode OVERLAY_FILE
# Only the architecture, UI and gate-mode readers call this guard (#2127).
# Compare literal entries. Regex equivalence cannot prove preserved coverage.
config_guard() {
  local setting="$1" default="$2" candidate="$3" direction="$4" overlay="$5"
  if [ -z "$candidate" ] || [ "$candidate" = null ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! jq -en --argjson d "$default" --argjson c "$candidate" --arg kind "$direction" '
    if $kind == "mode" then
      {off:0, observe:1, enforce:2} as $rank |
      ($rank[$c] != null and $rank[$c] >= $rank[$d])
    elif ($c | type) != "array" then false
    elif any($c[]; type != "string") then false
    elif $kind == "paths" then ($d - $c | length) == 0
    elif $kind == "excludes" then ($c - $d | length) == 0
    else false end' >/dev/null 2>&1; then
    printf 'WARN: ignoring loosening or invalid %s from overlay %s. Using project value.\n' "$setting" "$overlay" >&2
    printf '%s\n' "$default"
    return 0
  fi
  printf '%s\n' "$candidate"
}

# config_overlay SETTING BASELINE_JSON paths|excludes|mode [REPO_ROOT]
# The registry parent is the private repo used by portfolio_resolve_template.
# An in-fork registry is not a sibling overlay.
config_overlay() {
  local setting="$1" baseline="$2" direction="$3" repo="${4:-}" lib registry root overlay candidate
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -r "$lib/_lib-portfolio-paths.sh" ]; then
    # shellcheck source=/dev/null
    . "$lib/_lib-portfolio-paths.sh"
  else
    printf '%s\n' "$baseline"
    return 0
  fi
  root=$(_portfolio_root)
  registry=$(portfolio_registry)
  overlay=$(dirname "$registry")
  if [ -z "$root" ] || [ -z "$registry" ] || portfolio_path_under "$overlay" "$root" ||
      { [ -n "$repo" ] && portfolio_path_under "$overlay" "$repo"; }; then
    printf '%s\n' "$baseline"
    return 0
  fi
  overlay="$overlay/.claude/project-config.json"
  if [ ! -f "$overlay" ]; then
    printf '%s\n' "$baseline"
    return 0
  fi
  candidate=$(jq -c --arg setting "$setting" 'getpath($setting | split("."))' "$overlay" 2>/dev/null)
  config_guard "$setting" "$baseline" "$candidate" "$direction" "$overlay"
}

# Line-oriented adapter for the existing gate path and exclusion readers.
config_overlay_lines() {
  local setting="$1" lines="$2" direction="$3" repo="${4:-}" baseline
  baseline=$(printf '%s\n' "$lines" | jq -Rsc 'split("\n") | map(select(length > 0))')
  config_overlay "$setting" "$baseline" "$direction" "$repo" | jq -r '.[]'
}

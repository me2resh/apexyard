#!/bin/bash
# _lib-read-config.sh — shared reader for .claude/project-config.*.json
#
# Source this library from any hook or skill that needs to read project config.
# Defaults ship at .claude/project-config.defaults.json (committed, upstream-
# maintained). User overrides live at .claude/project-config.json (optional;
# each fork decides whether to commit or gitignore it).
#
# Merge strategy: SHALLOW at the top level. If the user defines `ticket`, their
# entire `ticket` subtree replaces the default. To extend a subtree, copy the
# default fields and add/modify. This keeps merge behaviour predictable without
# requiring a deep-merge jq function, and matches the "config file as a whole"
# mental model most teams expect.
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
#   config_get '.ticket.prefix_whitelist[]'
#   config_get '.branch.type_whitelist[]'
#   config_get '.ticket.label_priority_scheme'
#
# Silent fallback behaviour:
#   - No defaults file present: emit '{}' and an error on stderr. Callers should
#     treat config_get as "unknown" and apply their own safety.
#   - jq not installed: emit '{}' and a one-time warning on stderr.

# ------------------------------------------------------------------------------
# Internal state: cache merged config per-process so repeated reads are cheap.
# ------------------------------------------------------------------------------
_CONFIG_CACHE=""
_CONFIG_WARNED_NO_JQ=""

_config_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

_config_defaults_file() {
  local root
  root=$(_config_repo_root)
  [ -n "$root" ] && echo "$root/.claude/project-config.defaults.json"
}

_config_overrides_file() {
  local root
  root=$(_config_repo_root)
  [ -n "$root" ] && echo "$root/.claude/project-config.json"
}

_config_load() {
  # Check jq availability once per process.
  if ! command -v jq >/dev/null 2>&1; then
    if [ -z "$_CONFIG_WARNED_NO_JQ" ]; then
      echo "WARN: jq not installed; project config unavailable. Install jq to enable config-driven hooks." >&2
      _CONFIG_WARNED_NO_JQ=1
    fi
    echo '{}'
    return 0
  fi

  local defaults overrides
  defaults=$(_config_defaults_file)
  overrides=$(_config_overrides_file)

  if [ -z "$defaults" ] || [ ! -f "$defaults" ]; then
    # No defaults file — repo may not be an apexyard fork (e.g. project-inside-workspace).
    echo '{}'
    return 0
  fi

  if [ -f "$overrides" ]; then
    # Shallow merge: user overrides win at top-level keys.
    jq -s '.[0] * .[1]' "$defaults" "$overrides" 2>/dev/null || cat "$defaults"
  else
    cat "$defaults"
  fi
}

# ------------------------------------------------------------------------------
# Public: config_get <jq-filter>
#   Outputs the result of applying the filter to the merged config.
#   Returns an empty string (not an error) when the filter matches nothing.
# ------------------------------------------------------------------------------
config_get() {
  local filter="${1:-.}"
  if [ -z "$_CONFIG_CACHE" ]; then
    _CONFIG_CACHE=$(_config_load)
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "$_CONFIG_CACHE" | jq -r "$filter" 2>/dev/null
  else
    return 0
  fi
}

# ------------------------------------------------------------------------------
# Public: config_get_or <jq-filter> <fallback>
#   Like config_get, but returns <fallback> if the filter yields an empty
#   string, "null", or an error. Useful for single-value lookups with sensible
#   in-code defaults (e.g. when a hook runs outside an apexyard repo).
# ------------------------------------------------------------------------------
config_get_or() {
  local filter="$1"
  local fallback="$2"
  local value
  value=$(config_get "$filter")
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "$fallback"
  else
    echo "$value"
  fi
}

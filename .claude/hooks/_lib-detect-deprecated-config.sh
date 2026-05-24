#!/bin/bash
# _lib-detect-deprecated-config.sh — detect override keys absent from defaults
#
# Source this library from the /update skill (or any other tool) to surface
# top-level keys present in `.claude/project-config.json` (the adopter override)
# that are NOT present in `.claude/project-config.defaults.json` (the upstream-
# shipped defaults). The classic case is a config block removed upstream — for
# example `voice_prompts` removed in me2resh/apexyard#157 — that lingers in the
# adopter's override file as dead config.
#
# Output is ADVISORY ONLY. The helper never edits the override file. It just
# emits a newline-separated list of deprecated key names on stdout. The caller
# (a skill) decides what to do with that list — typically: prompt the operator
# y / n / s, then on `y` edit the override JSON via jq.
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-detect-deprecated-config.sh"
#   deprecated=$(detect_deprecated_config_keys)
#   for key in $deprecated; do echo "  - $key (no longer in upstream defaults)"; done
#
# Optional second arg lets callers point at non-default file paths (used by
# tests). When omitted, paths are derived from the repo root.
#
# Whitelist: metadata keys whose name starts with `_` (e.g. `_comment`,
# `_schema_version`) are always ignored. They're documentation / schema-version
# fields, not deprecated config blocks. The whitelist is intentionally simple —
# a leading underscore is the framework convention for non-config metadata.
#
# Custom-extension keys: an adopter may legitimately add their own top-level
# keys to the override (custom hooks, in-house extensions). The helper surfaces
# these the same way it surfaces upstream-removed keys — the caller's job is
# to make the offer informational, not destructive. The skill prompts y/n/s
# and the operator decides whether each flagged key is dead or load-bearing.

# ---------------------------------------------------------------------------
# Internal: resolve repo root when no explicit paths are passed.
# ---------------------------------------------------------------------------
_dep_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public: detect_deprecated_config_keys [defaults_path] [overrides_path]
#
# Emits one deprecated key name per line on stdout.
# Exit codes:
#   0 — completed (zero or more keys emitted)
#   1 — jq missing, or required input file missing — caller should treat
#       as "skip detection silently" rather than blocking the whole skill.
#
# Design notes:
#   - Reads only TOP-LEVEL keys. The ticket explicitly scopes this to whole-
#     block removals (e.g. `voice_prompts` as a whole), not to renamed keys
#     within a still-existing block. That deeper schema-versioning concern
#     is out of scope for v1 (see ticket § "Out of scope").
#   - Whitelist is hard-coded to the leading-underscore convention. This is
#     the simplest workable rule and matches every metadata field the
#     framework currently ships (`_comment`, `_schema_version`,
#     `_*_comment`). If the convention ever needs to broaden (adopter-added
#     allowlist), the function below is the one obvious place to plumb a
#     second argument.
# ---------------------------------------------------------------------------
detect_deprecated_config_keys() {
  local defaults="${1:-}"
  local overrides="${2:-}"

  if [ -z "$defaults" ] || [ -z "$overrides" ]; then
    local root
    root=$(_dep_repo_root)
    [ -z "$defaults" ] && defaults="$root/.claude/project-config.defaults.json"
    [ -z "$overrides" ] && overrides="$root/.claude/project-config.json"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "WARN: jq not installed; skipping deprecated-config detection." >&2
    return 1
  fi

  if [ ! -f "$defaults" ]; then
    # No defaults file — caller is not in an apexyard-shaped repo.
    return 1
  fi

  if [ ! -f "$overrides" ]; then
    # No override — by definition no deprecated keys to surface.
    return 0
  fi

  # jq:
  #   - keys: top-level key names in each file
  #   - subtract default keys from override keys
  #   - filter out leading-underscore metadata
  #   - emit one per line, sorted for stable output
  jq -r --slurpfile def "$defaults" '
    [keys[]] as $okeys
    | ($def[0] | keys) as $dkeys
    | $okeys
    | map(select(
        (. as $k | $dkeys | index($k) | not)
        and (startswith("_") | not)
      ))
    | sort
    | .[]
  ' "$overrides" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public: show_deprecated_config_keys [defaults_path] [overrides_path]
#
# Pretty-prints each deprecated key name and its current value (truncated to
# the first ~3 lines of jq's compact output) so the operator can decide
# whether each is dead config or a custom extension before answering y/n.
#
# Used by the [s]how branch of the /update prompt.
# ---------------------------------------------------------------------------
show_deprecated_config_keys() {
  local defaults="${1:-}"
  local overrides="${2:-}"

  if [ -z "$defaults" ] || [ -z "$overrides" ]; then
    local root
    root=$(_dep_repo_root)
    [ -z "$defaults" ] && defaults="$root/.claude/project-config.defaults.json"
    [ -z "$overrides" ] && overrides="$root/.claude/project-config.json"
  fi

  local keys
  keys=$(detect_deprecated_config_keys "$defaults" "$overrides")
  [ -z "$keys" ] && return 0

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    local value
    value=$(jq --arg k "$key" '.[$k]' "$overrides" 2>/dev/null | head -n 5)
    echo "  - $key:"
    echo "$value" | sed 's/^/      /'
  done <<<"$keys"
}

# ---------------------------------------------------------------------------
# Public: remove_deprecated_config_keys [defaults_path] [overrides_path]
#
# Edits the override file in place to remove every deprecated top-level key.
# Caller is expected to have already obtained explicit operator confirmation
# (the skill's y/n/s prompt) — this function does NOT prompt and does NOT
# commit. It just rewrites the JSON.
#
# Returns the count of removed keys on stdout (so the caller can report
# "removed N keys" without re-running detection).
# ---------------------------------------------------------------------------
remove_deprecated_config_keys() {
  local defaults="${1:-}"
  local overrides="${2:-}"

  if [ -z "$defaults" ] || [ -z "$overrides" ]; then
    local root
    root=$(_dep_repo_root)
    [ -z "$defaults" ] && defaults="$root/.claude/project-config.defaults.json"
    [ -z "$overrides" ] && overrides="$root/.claude/project-config.json"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "0"
    return 1
  fi

  local keys
  keys=$(detect_deprecated_config_keys "$defaults" "$overrides")
  if [ -z "$keys" ]; then
    echo "0"
    return 0
  fi

  # Build a jq filter that deletes each deprecated key.
  #   del(.foo, .bar, .baz)
  local filter="del("
  local first=1
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if [ "$first" -eq 1 ]; then
      filter="${filter}.\"${key}\""
      first=0
    else
      filter="${filter}, .\"${key}\""
    fi
  done <<<"$keys"
  filter="${filter})"

  local tmp
  tmp=$(mktemp)
  if jq "$filter" "$overrides" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$overrides"
    # shellcheck disable=SC2126  # `wc -l` is fine here; keys are newline-separated
    echo "$keys" | grep -c .
  else
    rm -f "$tmp"
    echo "0"
    return 1
  fi
}

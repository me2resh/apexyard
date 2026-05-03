#!/bin/bash
# _lib-portfolio-paths.sh — resolve portfolio paths from project-config.
#
# Source this library from any hook or skill that reads/writes the
# portfolio registry, per-project docs dir, or ideas backlog. Reads the
# `portfolio` block from .claude/project-config.{defaults,}.json (via
# _lib-read-config.sh's `config_get_or`).
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
#   registry=$(portfolio_registry)
#   projects_dir=$(portfolio_projects_dir)
#   ideas_backlog=$(portfolio_ideas_backlog)
#   portfolio_validate || echo "broken: $(portfolio_validate)"
#
# All resolvers output absolute paths. Relative config values resolve
# against the ops-fork root (dir containing both onboarding.yaml and
# apexyard.projects.yaml). Outside an apexyard fork the resolvers fall
# back to the current git toplevel; outside any git repo they output
# the relative literal so callers can detect the no-fork state.
#
# Defaults (when config is missing entirely):
#   registry      → ./apexyard.projects.yaml
#   projects_dir  → ./projects
#   ideas_backlog → ./projects/ideas-backlog.md
#
# Caching: results cached per-process in shell vars to avoid repeat jq
# calls. Same pattern as _CONFIG_CACHE in _lib-read-config.sh.

# ------------------------------------------------------------------------------
# Internal: resolve the ops-fork root (dir with onboarding.yaml AND
# apexyard.projects.yaml). Walks up from the git toplevel.
# Falls back to git toplevel if not inside an apexyard fork.
# ------------------------------------------------------------------------------
_PORTFOLIO_ROOT_CACHE=""
_portfolio_root() {
  if [ -n "$_PORTFOLIO_ROOT_CACHE" ]; then
    echo "$_PORTFOLIO_ROOT_CACHE"
    return 0
  fi

  local r
  r=$(git rev-parse --show-toplevel 2>/dev/null) || r=""
  if [ -z "$r" ]; then
    # Outside any git repo — caller decides what to do.
    return 0
  fi

  local cur="$r"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -f "$cur/onboarding.yaml" ] && [ -f "$cur/apexyard.projects.yaml" ]; then
      _PORTFOLIO_ROOT_CACHE="$cur"
      echo "$cur"
      return 0
    fi
    cur=$(dirname "$cur")
  done

  # Not under an apexyard fork — fall back to git toplevel so callers
  # working inside a managed-project clone (workspace/<name>/) still get
  # a sensible-ish answer (their own clone root).
  _PORTFOLIO_ROOT_CACHE="$r"
  echo "$r"
}

# ------------------------------------------------------------------------------
# Internal: resolve a possibly-relative path against the ops-fork root.
# Outputs an absolute path. If the input is already absolute, echo as-is.
# ------------------------------------------------------------------------------
_portfolio_resolve() {
  local p="$1"
  case "$p" in
    /*) echo "$p" ;;
    *)
      local root
      root=$(_portfolio_root)
      if [ -n "$root" ]; then
        # Strip leading ./ for tidier output.
        echo "$root/${p#./}"
      else
        # No root — return the literal so caller can detect.
        echo "$p"
      fi
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Internal: resolve one config key with a default. Source _lib-read-config.sh
# if it isn't already loaded (idempotent — sourcing twice is fine).
# ------------------------------------------------------------------------------
_portfolio_get() {
  local key="$1"
  local fallback="$2"

  if ! command -v config_get_or >/dev/null 2>&1; then
    local root
    root=$(_portfolio_root)
    if [ -n "$root" ] && [ -f "$root/.claude/hooks/_lib-read-config.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/.claude/hooks/_lib-read-config.sh"
    fi
  fi

  if command -v config_get_or >/dev/null 2>&1; then
    config_get_or "$key" "$fallback"
  else
    echo "$fallback"
  fi
}

# ------------------------------------------------------------------------------
# Public resolvers — each outputs an absolute path.
# Cached per-process.
# ------------------------------------------------------------------------------
_PORTFOLIO_REGISTRY_CACHE=""
portfolio_registry() {
  if [ -n "$_PORTFOLIO_REGISTRY_CACHE" ]; then
    echo "$_PORTFOLIO_REGISTRY_CACHE"
    return 0
  fi
  local raw
  raw=$(_portfolio_get '.portfolio.registry' './apexyard.projects.yaml')
  _PORTFOLIO_REGISTRY_CACHE=$(_portfolio_resolve "$raw")
  echo "$_PORTFOLIO_REGISTRY_CACHE"
}

_PORTFOLIO_PROJECTS_DIR_CACHE=""
portfolio_projects_dir() {
  if [ -n "$_PORTFOLIO_PROJECTS_DIR_CACHE" ]; then
    echo "$_PORTFOLIO_PROJECTS_DIR_CACHE"
    return 0
  fi
  local raw
  raw=$(_portfolio_get '.portfolio.projects_dir' './projects')
  _PORTFOLIO_PROJECTS_DIR_CACHE=$(_portfolio_resolve "$raw")
  echo "$_PORTFOLIO_PROJECTS_DIR_CACHE"
}

_PORTFOLIO_IDEAS_BACKLOG_CACHE=""
portfolio_ideas_backlog() {
  if [ -n "$_PORTFOLIO_IDEAS_BACKLOG_CACHE" ]; then
    echo "$_PORTFOLIO_IDEAS_BACKLOG_CACHE"
    return 0
  fi
  local raw
  raw=$(_portfolio_get '.portfolio.ideas_backlog' './projects/ideas-backlog.md')
  _PORTFOLIO_IDEAS_BACKLOG_CACHE=$(_portfolio_resolve "$raw")
  echo "$_PORTFOLIO_IDEAS_BACKLOG_CACHE"
}

# ------------------------------------------------------------------------------
# Public: portfolio_validate
#   Sanity-check that resolved paths are actually usable.
#   On success: prints nothing, returns 0.
#   On failure: prints "broken: <reason>" on stdout, returns 1.
#
#   Checks:
#     - registry file exists and is readable
#     - registry parses as YAML and contains a top-level `projects:` key
#     - projects_dir exists and is a directory
#     - ideas_backlog file exists OR its parent dir exists (creatable)
#
#   Cheap (~tens of ms with yq, ~1ms without) — safe to call from
#   SessionStart hooks without measurable session-start lag.
# ------------------------------------------------------------------------------
portfolio_validate() {
  local registry projects_dir ideas_backlog
  registry=$(portfolio_registry)
  projects_dir=$(portfolio_projects_dir)
  ideas_backlog=$(portfolio_ideas_backlog)

  if [ ! -f "$registry" ]; then
    echo "broken: portfolio.registry resolved to $registry — file does not exist"
    return 1
  fi
  if [ ! -r "$registry" ]; then
    echo "broken: portfolio.registry at $registry is not readable"
    return 1
  fi

  # Parse as YAML if yq is available; else minimal grep check.
  if command -v yq >/dev/null 2>&1; then
    if ! yq eval '.' "$registry" >/dev/null 2>&1; then
      echo "broken: portfolio.registry at $registry does not parse as valid YAML"
      return 1
    fi
    local has_projects
    has_projects=$(yq eval 'has("projects")' "$registry" 2>/dev/null)
    if [ "$has_projects" != "true" ]; then
      echo "broken: portfolio.registry at $registry has no top-level 'projects:' key"
      return 1
    fi
  else
    # yq not installed — minimal sanity check; don't block on parse depth.
    if ! grep -q '^projects:' "$registry" 2>/dev/null; then
      echo "broken: portfolio.registry at $registry has no top-level 'projects:' key (yq not installed; only doing grep check)"
      return 1
    fi
  fi

  if [ ! -d "$projects_dir" ]; then
    echo "broken: portfolio.projects_dir resolved to $projects_dir — directory does not exist"
    return 1
  fi

  if [ ! -f "$ideas_backlog" ]; then
    local parent
    parent=$(dirname "$ideas_backlog")
    if [ ! -d "$parent" ]; then
      echo "broken: portfolio.ideas_backlog at $ideas_backlog is missing AND its parent dir $parent does not exist"
      return 1
    fi
    # File missing but parent exists → creatable. Treat as OK.
  fi

  return 0
}

# ------------------------------------------------------------------------------
# Public: portfolio_clear_cache
#   Reset all per-process caches. Used by tests; rarely needed elsewhere.
# ------------------------------------------------------------------------------
portfolio_clear_cache() {
  _PORTFOLIO_ROOT_CACHE=""
  _PORTFOLIO_REGISTRY_CACHE=""
  _PORTFOLIO_PROJECTS_DIR_CACHE=""
  _PORTFOLIO_IDEAS_BACKLOG_CACHE=""
}

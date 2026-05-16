#!/bin/bash
# _lib-portfolio-paths.sh — resolve portfolio paths from project-config.
#
# Source this library from any hook or skill that reads/writes the
# portfolio registry, per-project docs dir, ideas backlog, the
# onboarding config, or the workspace dir. Reads the `portfolio` block
# from .claude/project-config.{defaults,}.json (via _lib-read-config.sh's
# `config_get_or`).
#
# Usage:
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
#   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
#   registry=$(portfolio_registry)
#   projects_dir=$(portfolio_projects_dir)
#   ideas_backlog=$(portfolio_ideas_backlog)
#   onboarding=$(portfolio_onboarding_path)         # framework ≥ #242
#   workspace_dir=$(portfolio_workspace_dir)        # framework ≥ #242
#   portfolio_validate || echo "broken: $(portfolio_validate)"
#
# All resolvers output absolute paths. Relative config values resolve
# against the ops-fork root. The ops-fork root is identified by EITHER:
#
#   - a `.apexyard-fork` marker file (split-portfolio v2 layout, where
#     onboarding.yaml + apexyard.projects.yaml live in the private
#     sibling repo), OR
#   - both `onboarding.yaml` AND `apexyard.projects.yaml` (legacy
#     single-fork OR un-migrated split-portfolio v1 layout)
#
# Outside an apexyard fork the resolvers fall back to the current git
# toplevel; outside any git repo they output the relative literal so
# callers can detect the no-fork state.
#
# Defaults (when config is missing entirely):
#   registry      → ./apexyard.projects.yaml
#   projects_dir  → ./projects
#   ideas_backlog → ./projects/ideas-backlog.md
#   onboarding    → ./onboarding.yaml
#   workspace_dir → ./workspace
#
# Caching: results cached per-process in shell vars to avoid repeat jq
# calls. Same pattern as _CONFIG_CACHE in _lib-read-config.sh.

# ------------------------------------------------------------------------------
# Internal: resolve the ops-fork root. Walks up from the git toplevel
# looking for the v2 marker (`.apexyard-fork`) first, falling back to
# the legacy v1 anchor (onboarding.yaml + apexyard.projects.yaml).
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
    # v2 anchor first (cheap presence test).
    if [ -f "$cur/.apexyard-fork" ]; then
      _PORTFOLIO_ROOT_CACHE="$cur"
      echo "$cur"
      return 0
    fi
    # Legacy v1 anchor.
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
# Public: portfolio_onboarding_path
#   Resolves the path to onboarding.yaml. In single-fork mode this is
#   inside the fork; in split-portfolio v2 mode it lives in the private
#   sibling repo (e.g. ../<fork>-portfolio/onboarding.yaml).
#
#   Default: ./onboarding.yaml (relative to ops-fork root)
# ------------------------------------------------------------------------------
_PORTFOLIO_ONBOARDING_CACHE=""
portfolio_onboarding_path() {
  if [ -n "$_PORTFOLIO_ONBOARDING_CACHE" ]; then
    echo "$_PORTFOLIO_ONBOARDING_CACHE"
    return 0
  fi
  local raw
  raw=$(_portfolio_get '.portfolio.onboarding' './onboarding.yaml')
  _PORTFOLIO_ONBOARDING_CACHE=$(_portfolio_resolve "$raw")
  echo "$_PORTFOLIO_ONBOARDING_CACHE"
}

# ------------------------------------------------------------------------------
# Public: portfolio_workspace_dir
#   Resolves the path to the workspace dir (where managed-project clones
#   live). In single-fork mode this is inside the fork; in split-portfolio
#   v2 mode it lives in the private sibling repo (e.g.
#   ../<fork>-portfolio/workspace).
#
#   Default: ./workspace (relative to ops-fork root)
# ------------------------------------------------------------------------------
_PORTFOLIO_WORKSPACE_DIR_CACHE=""
portfolio_workspace_dir() {
  if [ -n "$_PORTFOLIO_WORKSPACE_DIR_CACHE" ]; then
    echo "$_PORTFOLIO_WORKSPACE_DIR_CACHE"
    return 0
  fi
  local raw
  raw=$(_portfolio_get '.portfolio.workspace_dir' './workspace')
  _PORTFOLIO_WORKSPACE_DIR_CACHE=$(_portfolio_resolve "$raw")
  echo "$_PORTFOLIO_WORKSPACE_DIR_CACHE"
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
  local registry projects_dir ideas_backlog onboarding workspace_dir
  registry=$(portfolio_registry)
  projects_dir=$(portfolio_projects_dir)
  ideas_backlog=$(portfolio_ideas_backlog)
  onboarding=$(portfolio_onboarding_path)
  workspace_dir=$(portfolio_workspace_dir)

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

  # onboarding.yaml: validate ONLY when the resolved path is OUTSIDE the
  # ops-fork root (i.e. an explicit override pointing at a sibling repo,
  # split-portfolio v2 mode). When the resolved path is the in-fork
  # default, the onboarding-check.sh hook already handles the
  # missing/placeholder case with a more specific message; double-flagging
  # would be noisy on fresh forks before /setup runs.
  local root
  root=$(_portfolio_root)
  case "$onboarding" in
    "$root"/*|"$root")
      # In-fork path — leave it to onboarding-check.sh.
      ;;
    *)
      if [ ! -f "$onboarding" ]; then
        echo "broken: portfolio.onboarding resolved to $onboarding — file does not exist"
        return 1
      fi
      ;;
  esac

  # workspace_dir: same shape — only validate explicit overrides. The
  # in-fork default may legitimately not exist yet (no managed projects
  # cloned). Callers that need the dir should mkdir on demand.
  case "$workspace_dir" in
    "$root"/*|"$root")
      # In-fork path — optional; skip.
      ;;
    *)
      if [ ! -d "$workspace_dir" ]; then
        echo "broken: portfolio.workspace_dir resolved to $workspace_dir — directory does not exist"
        return 1
      fi
      # Writability check — read-only mounts (NFS / SMB / nested-container
      # bind-mounts that drop write perms) would otherwise silent-fail when
      # /handover or the v2 migration tries to write into workspace/.
      # Surface the failure here so SessionStart catches it.
      if [ ! -w "$workspace_dir" ]; then
        echo "broken: portfolio.workspace_dir at $workspace_dir is not writable"
        return 1
      fi
      ;;
  esac

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
  _PORTFOLIO_ONBOARDING_CACHE=""
  _PORTFOLIO_WORKSPACE_DIR_CACHE=""
}

# ------------------------------------------------------------------------------
# Public: portfolio_is_v2
#   Returns 0 if the ops fork is configured with the v2 layout (the
#   `.apexyard-fork` marker is present at the resolved root), 1 otherwise.
#   Useful for skills that want to branch behaviour on the layout (e.g.
#   `/update`'s migration step, `/setup`'s split-portfolio init).
# ------------------------------------------------------------------------------
portfolio_is_v2() {
  local root
  root=$(_portfolio_root)
  [ -n "$root" ] && [ -f "$root/.apexyard-fork" ]
}

# ------------------------------------------------------------------------------
# Public: portfolio_resolve_template <relative_path>
#   Resolves a template path with adopter-override semantics:
#     1. If <private_repo>/custom-templates/<relative_path> exists,
#        return its absolute path.
#     2. Else if <ops_root>/templates/<relative_path> exists,
#        return that absolute path.
#     3. Else return empty + nonzero exit (caller decides what to do).
#
#   <private_repo> is the directory holding the registry (resolved via
#   portfolio_registry's parent), so split-portfolio adopters drop
#   overrides next to their other portfolio data while single-fork
#   adopters fall straight through to the framework default.
#
#   The <relative_path> mirrors the framework's templates/ shape:
#     portfolio_resolve_template prd.md
#     portfolio_resolve_template architecture/c4-context.md
#     portfolio_resolve_template agdr-migration.md
#
#   Examples:
#     # Split-portfolio v2 with custom PRD shape:
#     portfolio_resolve_template prd.md
#     # → /home/me/ops/apexyard-portfolio/custom-templates/prd.md
#
#     # Single-fork adopter, no override:
#     portfolio_resolve_template prd.md
#     # → /home/me/ops/apexyard/templates/prd.md
#
#     # Neither exists:
#     portfolio_resolve_template does-not-exist.md   # exits 1
# ------------------------------------------------------------------------------
portfolio_resolve_template() {
  local rel="$1"
  if [ -z "$rel" ]; then
    return 1
  fi

  # Strip a leading ./ for tidier matches.
  rel="${rel#./}"

  # 1. Custom override under <private_repo>/custom-templates/.
  #    The "private repo" is the directory holding the registry — for
  #    single-fork adopters this is the ops-fork root (so
  #    custom-templates/ would also live in the fork, which is fine);
  #    for split-portfolio adopters it's the sibling private repo.
  local registry custom_dir custom_path
  registry=$(portfolio_registry)
  if [ -n "$registry" ]; then
    custom_dir=$(dirname "$registry")
    custom_path="$custom_dir/custom-templates/$rel"
    if [ -f "$custom_path" ]; then
      echo "$custom_path"
      return 0
    fi
  fi

  # 2. Framework default under <ops_root>/templates/.
  local root framework_path
  root=$(_portfolio_root)
  if [ -n "$root" ]; then
    framework_path="$root/templates/$rel"
    if [ -f "$framework_path" ]; then
      echo "$framework_path"
      return 0
    fi
  fi

  # 3. Neither exists.
  return 1
}

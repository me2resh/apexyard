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
#   agent_routing=$(portfolio_agent_routing)        # framework ≥ #351
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
#   custom_skills_dir    → ./custom-skills      (split-portfolio v2 + #243)
#   custom_handbooks_dir → ./custom-handbooks   (split-portfolio v2 + #243)
#   agent_routing → ./agent-routing.yaml        (#351, may not exist)
#
# Caching: results cached per-process in shell vars to avoid repeat jq
# calls. Same pattern as _CONFIG_CACHE in _lib-read-config.sh. On top of
# that, each resolver ALSO consults a session-scoped, CROSS-PROCESS cache
# (me2resh/apexyard#1013 / AgDR-0120) via
# _portfolio_resolve_with_session_cache — see that function and
# _lib-resolution-cache.sh's header for the full design. Falls through to
# the unchanged per-process logic on any miss; never changes what gets
# computed, only how often.

# ------------------------------------------------------------------------------
# Load _lib-ops-root.sh (for resolve_ops_root, consulted by _portfolio_root
# below) and the shared resolution-cache helpers (me2resh/apexyard#1013),
# if available, so the portfolio_* resolvers can consult the session-scoped
# cross-process cache. Best-effort: on any self-location failure this
# simply leaves the relevant functions undefined, and every call site below
# already treats "helper not defined" as "compute fresh, exactly as before
# this file existed" — see _portfolio_root and
# _portfolio_resolve_with_session_cache.
# ------------------------------------------------------------------------------
if ! command -v resolve_ops_root >/dev/null 2>&1 || ! command -v _resolution_cache_current_fingerprint >/dev/null 2>&1; then
  _PORTFOLIO_PATHS_RAW_BASH_SOURCE_0="${BASH_SOURCE[0]:-}"
  if [ -n "$_PORTFOLIO_PATHS_RAW_BASH_SOURCE_0" ]; then
    _portfolio_paths_lib_dir="$(cd "$(dirname "$_PORTFOLIO_PATHS_RAW_BASH_SOURCE_0")" 2>/dev/null && pwd)"
    if [ -n "$_portfolio_paths_lib_dir" ]; then
      if ! command -v resolve_ops_root >/dev/null 2>&1 && [ -f "$_portfolio_paths_lib_dir/_lib-ops-root.sh" ]; then
        # shellcheck source=/dev/null
        . "$_portfolio_paths_lib_dir/_lib-ops-root.sh"
      fi
      if ! command -v _resolution_cache_current_fingerprint >/dev/null 2>&1 && [ -f "$_portfolio_paths_lib_dir/_lib-resolution-cache.sh" ]; then
        # shellcheck source=/dev/null
        . "$_portfolio_paths_lib_dir/_lib-resolution-cache.sh"
      fi
    fi
    unset _portfolio_paths_lib_dir
  fi
  unset _PORTFOLIO_PATHS_RAW_BASH_SOURCE_0
fi

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

  # Prefer the shared, pin-aware resolver when available
  # (me2resh/apexyard#1013): resolve_ops_root() already has its own
  # cross-process cache (the ops-root-<session> pin, #381), so consulting
  # it here avoids redoing the walk-up below on every process when a pin
  # already answers the question. This is a consolidation, not a second
  # resolver — same anchor conditions as the walk below, so it can only
  # agree with what that walk would have found, never diverge from it
  # (the exact "two hand-maintained resolvers disagree" failure mode this
  # issue's own "Related" section warns about, apexyard-premium#537).
  #
  # Deliberately does NOT short-circuit on a resolve_ops_root() MISS:
  # unlike resolve_ops_root() (which returns empty when no anchor is
  # found above $start), _portfolio_root()'s own contract falls back to
  # the git toplevel itself for un-anchored managed-project clones (see
  # below) — a real, load-bearing behavioural difference this
  # consolidation must not erase.
  if command -v resolve_ops_root >/dev/null 2>&1; then
    local pinned
    pinned=$(resolve_ops_root "$r")
    if [ -n "$pinned" ]; then
      _PORTFOLIO_ROOT_CACHE="$pinned"
      echo "$pinned"
      return 0
    fi
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
    parent=$(dirname "$cur"); [ "$parent" = "$cur" ] && break; cur="$parent"
  done

  # Not under an apexyard fork — fall back to git toplevel so callers
  # working inside a managed-project clone (workspace/<name>/) still get
  # a sensible-ish answer (their own clone root).
  _PORTFOLIO_ROOT_CACHE="$r"
  echo "$r"
}

# ------------------------------------------------------------------------------
# Internal: canonicalize an ABSOLUTE path to its logical, `/../`-free,
# symlink-resolved form — WITHOUT requiring the leaf to already exist.
#
# Why this exists (me2resh/apexyard#945): callers of the public resolvers
# below (require-active-ticket.sh, require-migration-ticket.sh) compare a
# tool-supplied FILE_PATH against e.g. `portfolio_workspace_dir()` via a
# shell `case "$FILE_PATH" in "$WORKSPACE_DIR"/*)` prefix match. FILE_PATH
# arrives already normalised (no literal ".." component). Before this fix,
# a split-portfolio v2 adopter whose `portfolio.workspace_dir` override was
# a RELATIVE sibling path (e.g. "../<fork>-portfolio/workspace") got a
# resolved value that still contained a literal "/../" segment — e.g.
# "/Users/x/apexyard/../apexyard-portfolio/workspace" — because the old
# `_portfolio_resolve` just string-concatenated `$root/$p` with no
# normalisation. That literal "/../" never appears in a real FILE_PATH, so
# the prefix match silently failed and the per-project ticket marker
# (Tier 0/1) was ignored — legitimate edits got blocked (or fell through
# to the wrong tier).
#
# Algorithm mirrors `_resolve_real_path()` in _lib-path-resolve.sh (moved
# there from require-active-ticket.sh by PR #1087, Rex finding #4 — see
# that file's own header comment for why there is now exactly ONE
# definition instead of near-duplicate copies):
# walk up to the nearest EXISTING ancestor, physically resolve it via
# `cd ... && pwd -P` (which both collapses ".." and follows symlinks),
# then re-append whatever tail doesn't exist yet literally — a tail that
# doesn't exist yet cannot itself be a symlink or contain an unresolved
# "..", since dirname/basename already stripped those out of the walked
# portion. This is the same "realpath -m without depending on GNU
# coreutils" trick, needed because macOS/BSD doesn't guarantee GNU
# realpath's -m/-e flags are available.
#
# Fails soft: if $p can't be resolved for any reason (cd denied, etc.),
# echoes the original input unchanged rather than an empty/broken path —
# unlike require-active-ticket.sh's fail-CLOSED security check, a
# portfolio path resolver has no "block on doubt" contract to uphold.
#
# Windows/MSYS drive-letter normalization (me2resh/apexyard#1018): on
# Windows Git Bash, `git rev-parse --show-toplevel` (git.exe is a native
# Windows binary) returns a drive-letter path like "D:/Projs/fork", but
# `cd ... && pwd -P` (run directly by bash, an MSYS binary) returns the
# MSYS mount-point form "/d/Projs/fork" for the SAME location. The two
# spellings are byte-different for one identical path. Before this fix,
# the `case "$p" in /*)` guard below didn't recognize a drive-letter path
# as absolute at all, so it hit the `*)` fallback and was returned RAW,
# un-normalized — while a caller that instead ran `cd "$root" && pwd -P`
# directly (portfolio_validate's root_real/wd_real) got the MSYS form.
# Comparing the two forms via a string prefix match then always failed,
# even for a perfectly valid, non-split single-fork setup.
#
# Fix: normalize a leading `<letter>:/` or `<letter>:\` to `/<letter>/`
# BEFORE the absolute-path check, as a pure string transform — no
# dependency on cygpath (absent on macOS/Linux) or on cd/pwd actually
# resolving a real drive letter (which only MSYS's runtime does). This
# is a no-op for every POSIX path: a real absolute path always starts
# with "/", never with "<letter>:", so this branch is simply never
# entered outside a Windows-drive-letter input.
# ------------------------------------------------------------------------------
_portfolio_canonicalize() {
  local p="$1" dir tail=""

  case "$p" in
    [A-Za-z]:/*|[A-Za-z]:\\*)
      local drive rest
      drive="${p%%:*}"
      rest="${p#*:}"
      rest="$(printf '%s' "$rest" | tr '\\' '/')"
      drive="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
      p="/${drive}${rest}"
      ;;
  esac

  case "$p" in
    /*) : ;;
    *) echo "$p"; return 0 ;;  # not absolute — nothing to canonicalize
  esac

  dir="$p"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -e "$dir" ]; do
    if [ -z "$tail" ]; then
      tail="$(basename "$dir")"
    else
      tail="$(basename "$dir")/$tail"
    fi
    dir="$(dirname "$dir")"
  done

  if [ ! -e "$dir" ]; then
    echo "$p"
    return 0
  fi

  if [ -d "$dir" ]; then
    dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  else
    # $dir resolved to an existing FILE (not a directory) partway through
    # the walk — canonicalize its parent and re-append its own basename.
    local parent
    parent="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)"
    if [ -n "$parent" ]; then
      dir="$parent/$(basename "$dir")"
    else
      dir=""
    fi
  fi

  if [ -z "$dir" ]; then
    echo "$p"
    return 0
  fi

  if [ -n "$tail" ]; then
    if [ "$dir" = "/" ]; then
      printf '%s%s' "$dir" "$tail"
    else
      printf '%s/%s' "$dir" "$tail"
    fi
  else
    printf '%s' "$dir"
  fi
}

# ------------------------------------------------------------------------------
# Internal: resolve a possibly-relative path against the ops-fork root.
# Outputs an absolute, canonical (symlink-free, `/../`-free) path. If the
# input is already absolute, it is still canonicalized — an absolute
# override in project-config.json could itself carry a relative segment
# (e.g. "$SIBLING/../other").
#
# Absoluteness has TWO spellings, not one (me2resh/apexyard#1034). #1029
# taught `_portfolio_canonicalize` (below) to normalize a Windows
# drive-letter prefix, but left this function's own test as a bare `/*)`.
# A drive-letter path IS absolute and does NOT start with "/", so it fell
# into the relative arm and got concatenated onto the ops-fork root:
#
#   .portfolio.registry: "D:/Portfolio/apexyard.projects.yaml"
#     -> /Users/fork/D:/Portfolio/apexyard.projects.yaml
#
# The drive-letter arm below mirrors the pattern `_portfolio_canonicalize`
# already uses, so the two functions now agree on what "absolute" means.
#
# Deliberately NOT matched: drive-RELATIVE spellings (`C:foo`, bare `C:`).
# `C:foo` means "foo, relative to the current directory ON drive C" — it is
# genuinely not absolute, and treating it as such would resolve it somewhere
# the caller never asked for. The `[/\\]` after the colon is what draws that
# line, and it is load-bearing: do not relax it to a bare `[A-Za-z]:*)`.
# Pinned by the drive-relative case in
# tests/test_portfolio_paths_windows_drive_letter.sh.
# ------------------------------------------------------------------------------
_portfolio_resolve() {
  local p="$1" abs
  case "$p" in
    /*) abs="$p" ;;
    [A-Za-z]:/*|[A-Za-z]:\\*) abs="$p" ;;
    *)
      local root
      root=$(_portfolio_root)
      if [ -n "$root" ]; then
        # Strip leading ./ for tidier output.
        abs="$root/${p#./}"
      else
        # No root — return the literal so caller can detect.
        echo "$p"
        return 0
      fi
      ;;
  esac
  _portfolio_canonicalize "$abs"
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
# Internal: shared session-cache-aware resolution (me2resh/apexyard#1013 /
# AgDR-0120). Every portfolio_* resolver below RESOLVES to a value that
# depends on (config, ops root), but the fingerprint that governs the
# cache's validity — the SAME one _lib-read-config.sh's merged config
# cache uses — tracks only config (project-config.defaults.json +
# project-config.json). The ops root is deliberately NOT a fingerprint
# input (me2resh/apexyard#1013 follow-up, F2): it cannot change within a
# session (resolve_ops_root(), #381, pins it once per
# $CLAUDE_CODE_SESSION_ID), and every cache file this library writes is
# already scoped into its filename by that same session id — so there is
# no within-session root change for a fingerprint component to guard
# against. See _lib-resolution-cache.sh's _resolution_cache_config_fingerprint
# for the full writeup. One shared implementation tries the session cache
# first, falling through to the existing _portfolio_get + _portfolio_resolve
# chain (unchanged) on any miss. Callers store the result in THEIR OWN
# per-process _PORTFOLIO_*_CACHE var, exactly as before — this only changes
# HOW a per-process cache miss gets computed, never what gets computed or
# how a per-process HIT is served.
#
# <cache_name> is a short, hardcoded literal used as the session cache
# file's suffix (see _lib-resolution-cache.sh's _resolution_cache_file) —
# never derived from tool input.
# ------------------------------------------------------------------------------
_portfolio_resolve_with_session_cache() {
  local cache_name="$1" config_key="$2" default="$3"

  local fp cached
  if command -v _resolution_cache_current_fingerprint >/dev/null 2>&1; then
    fp=$(_resolution_cache_current_fingerprint)
    if [ "$fp" != "UNKNOWN" ]; then
      if cached=$(_resolution_cache_read "$cache_name" "$fp" 2>/dev/null) && [ -n "$cached" ]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  local raw resolved
  raw=$(_portfolio_get "$config_key" "$default")
  resolved=$(_portfolio_resolve "$raw")

  if [ -n "${fp:-}" ] && [ "$fp" != "UNKNOWN" ]; then
    _resolution_cache_write "$cache_name" "$fp" "$resolved" 2>/dev/null || true
  fi

  printf '%s' "$resolved"
}

# ------------------------------------------------------------------------------
# Public resolvers — each outputs an absolute path.
# Cached per-process, and (me2resh/apexyard#1013) cross-process via
# _portfolio_resolve_with_session_cache above.
# ------------------------------------------------------------------------------
_PORTFOLIO_REGISTRY_CACHE=""
portfolio_registry() {
  if [ -n "$_PORTFOLIO_REGISTRY_CACHE" ]; then
    echo "$_PORTFOLIO_REGISTRY_CACHE"
    return 0
  fi
  _PORTFOLIO_REGISTRY_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-registry" '.portfolio.registry' './apexyard.projects.yaml')
  echo "$_PORTFOLIO_REGISTRY_CACHE"
}

_PORTFOLIO_PROJECTS_DIR_CACHE=""
portfolio_projects_dir() {
  if [ -n "$_PORTFOLIO_PROJECTS_DIR_CACHE" ]; then
    echo "$_PORTFOLIO_PROJECTS_DIR_CACHE"
    return 0
  fi
  _PORTFOLIO_PROJECTS_DIR_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-projects-dir" '.portfolio.projects_dir' './projects')
  echo "$_PORTFOLIO_PROJECTS_DIR_CACHE"
}

_PORTFOLIO_IDEAS_BACKLOG_CACHE=""
portfolio_ideas_backlog() {
  if [ -n "$_PORTFOLIO_IDEAS_BACKLOG_CACHE" ]; then
    echo "$_PORTFOLIO_IDEAS_BACKLOG_CACHE"
    return 0
  fi
  _PORTFOLIO_IDEAS_BACKLOG_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-ideas-backlog" '.portfolio.ideas_backlog' './projects/ideas-backlog.md')
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
  _PORTFOLIO_ONBOARDING_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-onboarding" '.portfolio.onboarding' './onboarding.yaml')
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
  _PORTFOLIO_WORKSPACE_DIR_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-workspace-dir" '.portfolio.workspace_dir' './workspace')
  echo "$_PORTFOLIO_WORKSPACE_DIR_CACHE"
}

# ------------------------------------------------------------------------------
# Public: portfolio_custom_skills_dir
#   Resolves the path to the company-private custom-skills directory. In
#   single-fork mode this defaults to an in-fork path (rarely used — adopters
#   can drop a custom skill straight into .claude/skills/<name>/ if they
#   don't need split-portfolio privacy). In split-portfolio v2 mode this
#   lives in the private sibling repo (e.g. ../<fork>-portfolio/custom-skills).
#
#   The link-custom-skills.sh SessionStart hook reads this path and creates
#   gitignored symlinks at .claude/skills/<name>/ for each subdirectory it
#   finds.
#
#   Default: ./custom-skills (relative to ops-fork root)
# ------------------------------------------------------------------------------
_PORTFOLIO_CUSTOM_SKILLS_DIR_CACHE=""
portfolio_custom_skills_dir() {
  if [ -n "$_PORTFOLIO_CUSTOM_SKILLS_DIR_CACHE" ]; then
    echo "$_PORTFOLIO_CUSTOM_SKILLS_DIR_CACHE"
    return 0
  fi
  _PORTFOLIO_CUSTOM_SKILLS_DIR_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-custom-skills-dir" '.portfolio.custom_skills_dir' './custom-skills')
  echo "$_PORTFOLIO_CUSTOM_SKILLS_DIR_CACHE"
}

# ------------------------------------------------------------------------------
# Public: portfolio_custom_handbooks_dir
#   Resolves the path to the company-private custom-handbooks directory.
#   Same shape as portfolio_custom_skills_dir but for adopter coding
#   standards (the Rex agent reads this path as a second discovery source
#   beyond the public-fork's handbooks/ tree).
#
#   Default: ./custom-handbooks (relative to ops-fork root)
# ------------------------------------------------------------------------------
_PORTFOLIO_CUSTOM_HANDBOOKS_DIR_CACHE=""
portfolio_custom_handbooks_dir() {
  if [ -n "$_PORTFOLIO_CUSTOM_HANDBOOKS_DIR_CACHE" ]; then
    echo "$_PORTFOLIO_CUSTOM_HANDBOOKS_DIR_CACHE"
    return 0
  fi
  _PORTFOLIO_CUSTOM_HANDBOOKS_DIR_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-custom-handbooks-dir" '.portfolio.custom_handbooks_dir' './custom-handbooks')
  echo "$_PORTFOLIO_CUSTOM_HANDBOOKS_DIR_CACHE"
}

# ------------------------------------------------------------------------------
# Public: portfolio_agent_routing
#   Resolves the path to the adopter's agent-routing.yaml — the
#   centralised per-agent model + endpoint override surface (AgDR-0050
#   Axis 3, ticket #351).
#
#   Split-portfolio (v2) mode: the file lives in the sibling private
#   repo and is resolved via .portfolio.agent_routing in
#   .claude/project-config.json (e.g.
#   ../<fork>-portfolio/agent-routing.yaml).
#
#   Single-fork mode: the file lives at the fork root and is gitignored
#   (adopter-specific routing choices stay local; never leak to the
#   public fork). The default resolves to ./agent-routing.yaml relative
#   to the ops-fork root.
#
#   Unlike the other portfolio resolvers, this one is allowed to point
#   at a non-existent file — the absence of agent-routing.yaml means
#   "no overrides; framework defaults apply", which is the documented
#   out-of-box behaviour. Callers that need "exists or empty" should
#   test [ -f "$(portfolio_agent_routing)" ] themselves.
#
#   Returns: absolute path to agent-routing.yaml (may not exist yet).
#
#   Default: ./agent-routing.yaml (relative to ops-fork root)
# ------------------------------------------------------------------------------
_PORTFOLIO_AGENT_ROUTING_CACHE=""
portfolio_agent_routing() {
  if [ -n "$_PORTFOLIO_AGENT_ROUTING_CACHE" ]; then
    echo "$_PORTFOLIO_AGENT_ROUTING_CACHE"
    return 0
  fi
  _PORTFOLIO_AGENT_ROUTING_CACHE=$(_portfolio_resolve_with_session_cache "portfolio-agent-routing" '.portfolio.agent_routing' './agent-routing.yaml')
  echo "$_PORTFOLIO_AGENT_ROUTING_CACHE"
}

# ------------------------------------------------------------------------------
# Public: portfolio_path_eq <a> <b>
#   Case-insensitive-filesystem-aware equality check for two absolute
#   paths — do they name the SAME filesystem entry?
#
#   Why this exists (me2resh/apexyard#1104): on a case-insensitive
#   filesystem (macOS/APFS default, Windows), two path strings that
#   differ only in letter-case can be the identical on-disk directory.
#   `git rev-parse --show-toplevel` resolves via the OS and always
#   returns the canonical on-disk case (verified: `git -C
#   /path/to/lowercase rev-parse --show-toplevel` still returns the
#   canonical-cased path), but bash's `cd`/`pwd -P` do NOT re-case —
#   verified empirically: `cd lowercase-path && pwd -P` returns
#   "lowercase-path" unchanged, not the on-disk canonical case, on both
#   GNU bash 5.x and macOS's stock `/bin/bash` 3.2. So a path resolved
#   via `git rev-parse` (canonical) and a path resolved via a raw
#   `$PWD`-derived string (whatever case the operator or harness
#   originally typed) can be the SAME directory yet compare unequal with
#   a plain `=`/`case` string match — which is exactly how a case-only
#   difference between the ops-fork root and a portfolio path used to
#   get misread as "two distinct repos" (a phantom split-portfolio /
#   broken-config banner on a plain single-fork setup).
#
#   Strategy: prefer `-ef` (device+inode identity — the POSIX `test`
#   operator, immune to case entirely) when both paths exist. Fall back
#   to a case-folded string comparison when one/both don't exist yet
#   (e.g. a workspace_dir that hasn't been created) — `-ef` needs a
#   stat(2) on both sides. The fallback intentionally folds case
#   UNCONDITIONALLY rather than trying to detect "is this filesystem
#   case-insensitive": a false-positive fold on a case-SENSITIVE
#   filesystem (treating two genuinely-different directories as equal)
#   is the rarer, lower-cost failure mode next to the false "split
#   portfolio" this helper exists to eliminate on every case-insensitive
#   Mac/Windows setup — and the fold only ever applies to the
#   non-existent-path fallback, where there is no inode to be wrong
#   about in the first place.
# ------------------------------------------------------------------------------
portfolio_path_eq() {
  local a="$1" b="$2"

  [ "$a" = "$b" ] && return 0

  if [ -e "$a" ] && [ -e "$b" ] && [ "$a" -ef "$b" ]; then
    return 0
  fi

  local a_lc b_lc
  a_lc=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
  b_lc=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
  [ "$a_lc" = "$b_lc" ]
}

# ------------------------------------------------------------------------------
# Public: portfolio_path_under <path> <dir>
#   Case-insensitive-filesystem-aware containment check — is <path> equal
#   to <dir>, or does it live somewhere under <dir>? The prefix-match
#   sibling of portfolio_path_eq, for the same reason (see its header
#   comment above).
#
#   Strategy: walk UP from <path> (via dirname) to each ancestor that
#   actually exists, and -ef-compare it against <dir> — this correctly
#   handles <path> not existing yet (a file/dir that hasn't been created)
#   by climbing past the non-existent tail, the same existing-ancestor
#   pattern _portfolio_canonicalize already uses. Falls back to a
#   case-folded string prefix match when <dir> itself doesn't exist
#   (nothing to -ef against) or no existing ancestor of <path> matched.
# ------------------------------------------------------------------------------
portfolio_path_under() {
  local path="$1" dir="$2"

  [ -z "$dir" ] && return 1

  portfolio_path_eq "$path" "$dir" && return 0

  if [ -e "$dir" ]; then
    local cur="$path"
    while [ -n "$cur" ] && [ "$cur" != "/" ]; do
      if [ -e "$cur" ] && [ "$cur" -ef "$dir" ]; then
        return 0
      fi
      local parent
      parent=$(dirname "$cur")
      [ "$parent" = "$cur" ] && break
      cur="$parent"
    done
  fi

  local path_lc dir_lc
  path_lc=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
  dir_lc=$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]')
  case "$path_lc" in
    "$dir_lc"|"$dir_lc"/*) return 0 ;;
  esac
  return 1
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

  # Partial split-portfolio v2 detection — see me2resh/apexyard#373.
  # The registry and projects_dir are the v1 keys that turn a fork into a
  # split-portfolio v2 setup when overridden to sibling paths. If either is
  # sibling-pointing but workspace_dir falls back to the in-fork default,
  # the asymmetry is silent — clones accumulate in the public fork while
  # docs land in the sibling. Surface the gap so SessionStart catches it.
  # (onboarding gets its own validation below; it doesn't trigger this
  # check because adopters legitimately centralise company config without
  # going split-portfolio v2.)
  local root_real wd_real
  root_real=$(cd "$root" 2>/dev/null && pwd -P) || root_real="$root"
  wd_real=$(cd "$workspace_dir" 2>/dev/null && pwd -P) || wd_real="$workspace_dir"

  # Case-insensitive-filesystem-aware containment check (me2resh/apexyard#1104).
  # A plain string prefix match here misreads a case-only difference (e.g.
  # $root resolved via git rev-parse's canonical case vs a path built from
  # a raw, differently-cased cwd) as "outside the fork" — see
  # portfolio_path_under's header comment for the full mechanism.
  _outside_fork() {
    ! portfolio_path_under "$1" "$root_real"
  }

  if _outside_fork "$registry" || _outside_fork "$projects_dir"; then
    if ! _outside_fork "$wd_real"; then
      echo "broken: partial split-portfolio v2 config — registry/projects_dir point at a sibling repo but workspace_dir falls back to the in-fork default; set .portfolio.workspace_dir in .claude/project-config.json to the sibling path (e.g. \"../<fork>-portfolio/workspace\"). See me2resh/apexyard#373."
      return 1
    fi
  fi

  # Fork-containment check — see me2resh/apexyard#951 (and #952 for the
  # false-positive fix below).
  #
  # A projects_dir/workspace_dir override that's meant to point at the
  # sibling portfolio repo but has the wrong `../` depth (or a missing
  # leading `../`) can resolve to a real, but WRONG, directory INSIDE the
  # ops fork. The plain existence check earlier in this function passes —
  # the decoy dir genuinely exists — so the misconfig stays silent and
  # subsequent writes (clones, docs, registry edits) land in the wrong
  # tree. Close that gap by resolving each dir to its canonical
  # (`cd && pwd -P`) form and flagging if it lands inside.
  #
  # GATE ON THE RESOLVED LOCATION, NOT on portfolio_is_v2 (#952). Flag only
  # when a dir resolves INSIDE the ops fork at a NON-DEFAULT location. The
  # in-fork DEFAULTS ($root/projects, $root/workspace) are correct
  # single-fork behaviour and must never be flagged; a sibling-intended
  # override with the wrong `../` depth (or a missing leading `../`) lands
  # inside the fork at some OTHER path, which is the misconfig #951 catches.
  #
  # The old `portfolio_is_v2` gate false-positived because single-fork forks
  # ALSO carry the `.apexyard-fork` marker (it's written on every /setup,
  # single-fork or split), so the marker can't tell a legit in-fork default
  # from a sibling-intended override — see #952. Comparing the resolved path
  # against the canonical default location is immune to that ambiguity and
  # needs no (root-resolution-sensitive) config-key read.
  local pd_real
  pd_real=$(cd "$projects_dir" 2>/dev/null && pwd -P) || pd_real="$projects_dir"
  if ! _outside_fork "$pd_real" && ! portfolio_path_eq "$pd_real" "$root_real/projects"; then
    echo "broken: split-portfolio v2 misconfig — portfolio.projects_dir resolved to $projects_dir, which is INSIDE the ops fork ($root_real) rather than the sibling private-portfolio repo. Check for a '../' depth mismatch (or a missing leading '../') in .claude/project-config.json's portfolio.projects_dir override. See me2resh/apexyard#951."
    return 1
  fi

  if ! _outside_fork "$wd_real" && ! portfolio_path_eq "$wd_real" "$root_real/workspace"; then
    echo "broken: split-portfolio v2 misconfig — portfolio.workspace_dir resolved to $workspace_dir, which is INSIDE the ops fork ($root_real) rather than the sibling private-portfolio repo. Check for a '../' depth mismatch (or a missing leading '../') in .claude/project-config.json's portfolio.workspace_dir override. See me2resh/apexyard#951."
    return 1
  fi

  if portfolio_path_under "$onboarding" "$root"; then
    : # In-fork path — leave it to onboarding-check.sh.
  else
    if [ ! -f "$onboarding" ]; then
      echo "broken: portfolio.onboarding resolved to $onboarding — file does not exist"
      return 1
    fi
  fi

  # workspace_dir: same shape — only validate explicit overrides. The
  # in-fork default may legitimately not exist yet (no managed projects
  # cloned). Callers that need the dir should mkdir on demand.
  if portfolio_path_under "$workspace_dir" "$root"; then
    : # In-fork path — optional; skip.
  else
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
  _PORTFOLIO_ONBOARDING_CACHE=""
  _PORTFOLIO_WORKSPACE_DIR_CACHE=""
  _PORTFOLIO_CUSTOM_SKILLS_DIR_CACHE=""
  _PORTFOLIO_CUSTOM_HANDBOOKS_DIR_CACHE=""
  _PORTFOLIO_AGENT_ROUTING_CACHE=""
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

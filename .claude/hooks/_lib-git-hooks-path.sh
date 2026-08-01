#!/bin/bash
# _lib-git-hooks-path.sh — shared core.hooksPath detection logic.
#
# Sourced by:
#   - bin/install-git-hooks.sh              (mutates core.hooksPath)
#   - .claude/hooks/check-git-hooks-installed.sh  (advisory, read-only)
#
# Kept as a single shared lib so the installer and the advisory banner can
# never drift on what counts as "unset" / "correct" / "stale" / "deliberate
# third-party" — see me2resh/apexyard#1086.

# _resolve_real_path is sourced from _lib-path-resolve.sh — the single
# shared definition (PR #1087 review, Rex finding #4). This file used to
# carry its own inline copy with a comment claiming it was deliberately
# separate from require-active-ticket.sh's; that "copied verbatim, not
# sourced" shape is exactly the AgDR-0113 pattern #1086 exists to retire,
# and the two copies had already started drifting. See
# _lib-path-resolve.sh's header comment for the full rationale, including
# why it is NOT the same thing as _lib-portfolio-paths.sh's
# `_portfolio_canonicalize` (a deliberately different, fail-soft sibling).
# SELF-LOCATION BOOTSTRAP (me2resh/apexyard#1102 / AgDR-0118)
# ------------------------------------------------------------
# Was `_LGHP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"` --
# the `:-$0` fallback is a FAKE fix: under zsh, $0 in a sourced file is the
# sourcing invocation path AS TYPED, not a reliable self-location signal, so
# it inherits the exact same "dirname resolves to the caller's cwd" hazard
# `:-` alone has. The bootstrap guard below (raw BASH_SOURCE[0] captured
# once, empty short-circuits to no self-location, never $0) plus
# `resolve_anchored_lib_dir` in _lib-ops-root.sh (the anchor check) are the
# ONE shared idiom every _lib-*.sh self-location site now uses -- see that
# function's header for why the very first hop can never itself be
# centralized behind a sourced call.
_LGHP_RAW_BASH_SOURCE_0="${BASH_SOURCE[0]:-}"
_LGHP_LIB_DIR=""
if [ -n "$_LGHP_RAW_BASH_SOURCE_0" ]; then
  _LGHP_CANDIDATE_DIR="$(cd "$(dirname "$_LGHP_RAW_BASH_SOURCE_0")" 2>/dev/null && pwd)"
  if [ -n "$_LGHP_CANDIDATE_DIR" ] && [ -f "$_LGHP_CANDIDATE_DIR/_lib-ops-root.sh" ]; then
    # shellcheck source=./_lib-ops-root.sh
    # shellcheck disable=SC1091
    . "$_LGHP_CANDIDATE_DIR/_lib-ops-root.sh"
    if command -v resolve_anchored_lib_dir >/dev/null 2>&1; then
      _LGHP_LIB_DIR="$(resolve_anchored_lib_dir "$_LGHP_RAW_BASH_SOURCE_0")"
    fi
  fi
  unset _LGHP_CANDIDATE_DIR
fi
unset _LGHP_RAW_BASH_SOURCE_0

if [ -n "$_LGHP_LIB_DIR" ] && [ -f "$_LGHP_LIB_DIR/_lib-path-resolve.sh" ]; then
  # shellcheck source=/dev/null
  . "$_LGHP_LIB_DIR/_lib-path-resolve.sh"
else
  # DELIBERATE DEGRADE, not an oversight (#1089 — closing #1087's LOW-2).
  # Mirrors require-active-ticket.sh's own else-branch (see that file for
  # the long version of this reasoning). This lib is sourced by TWO
  # different consumers, and the missing-lib degrade is safe for both:
  #
  #   - check-git-hooks-installed.sh (SessionStart, advisory, exit 0
  #     always): an empty resolve here makes ghp_classify report "missing"
  #     even for an already-correct core.hooksPath, so the advisory banner
  #     fires with a spurious "doesn't exist" nudge on a clone that's
  #     actually fine. Over-warning, never silent — the safe direction for
  #     an advisory that exists to make sure nobody's terminal `git push`
  #     is silently unprotected.
  #   - bin/install-git-hooks.sh: that script has its OWN direct calls to
  #     _resolve_real_path (see the comment at its `. "$LIB"` line for how
  #     this same stand-in ends up covering those too) and its OWN
  #     "load-bearing ordering" comment explaining why it fails closed
  #     rather than clobbering a deliberate third-party core.hooksPath.
  #
  # Stand-in always echoes nothing — the same "unresolvable" contract the
  # real _resolve_real_path's own header comment describes — printed as a
  # named diagnostic once per process rather than bash's raw
  # "command not found" on every call.
  _resolve_real_path() {
    if [ -z "${_LGHP_PATH_RESOLVE_WARNED:-}" ]; then
      echo "ApexYard: _lib-path-resolve.sh is missing next to _lib-git-hooks-path.sh — path resolution is degrading (fail-closed / over-warn, never silently exempt). This should not happen in a normal clone; see me2resh/apexyard#1089." >&2
      _LGHP_PATH_RESOLVE_WARNED=1
    fi
    return 0
  }
fi

# ------------------------------------------------------------------------
# ghp_classify REPO_ROOT HOOKS_DIR_NAME
#
# REPO_ROOT must already be an absolute, resolved git toplevel path.
# HOOKS_DIR_NAME is the tracked hooks dir name relative to REPO_ROOT
# (default convention: ".githooks").
#
# Prints exactly one of, to stdout (no trailing newline):
#
#   unset
#     core.hooksPath has no value in this clone's git config.
#
#   correct
#     core.hooksPath resolves exactly to REPO_ROOT/HOOKS_DIR_NAME.
#
#   missing:<raw>
#     core.hooksPath is set to <raw>, which resolves to a path that does
#     not exist on disk (a deleted directory, a typo, or a config value
#     copied from a machine/clone that no longer has that path).
#
#   foreign-git-dir:<raw>:<resolved>
#     core.hooksPath resolves to an existing directory, but that
#     directory sits inside SOME repo's .git directory (path contains a
#     `.git` component) and is outside REPO_ROOT. A tracked hooks dir can
#     never legitimately live inside `.git/` (that directory is never
#     committed), so this can only be a stale absolute path left over
#     from a different clone's default hooks location — the concrete
#     failure mode #1086 was filed against.
#
#   third-party:<raw>:<resolved>
#     core.hooksPath resolves to an existing, real directory that is
#     neither of the above — could be inside REPO_ROOT under a different
#     name, or a genuinely external directory an adopter configured on
#     purpose (e.g. a company-wide shared hooks dir). Ambiguous by
#     design: treated as a deliberate adopter choice, never auto-repaired.
# ------------------------------------------------------------------------
ghp_classify() {
  local repo_root="$1" hooks_dir_name="$2"
  local current current_resolved target_resolved

  current=$(git -C "$repo_root" config --get core.hooksPath 2>/dev/null || true)
  target_resolved=$(_resolve_real_path "$repo_root/$hooks_dir_name")

  if [ -z "$current" ]; then
    printf 'unset'
    return 0
  fi

  case "$current" in
    /*) current_resolved=$(_resolve_real_path "$current") ;;
    *)  current_resolved=$(_resolve_real_path "$repo_root/$current") ;;
  esac

  if [ -n "$current_resolved" ] && [ "$current_resolved" = "$target_resolved" ]; then
    printf 'correct'
    return 0
  fi

  if [ -z "$current_resolved" ] || [ ! -d "$current_resolved" ]; then
    printf 'missing:%s' "$current"
    return 0
  fi

  # Inside REPO_ROOT but under a different name than HOOKS_DIR_NAME — a
  # real directory the adopter (or a script) deliberately created in this
  # very repo. Ambiguous-by-design: third-party, not stale.
  case "$current_resolved" in
    "$repo_root"/*)
      printf 'third-party:%s:%s' "$current" "$current_resolved"
      return 0
      ;;
  esac

  # Outside REPO_ROOT. If it sits inside a `.git` directory anywhere on
  # its path, it cannot be a tracked hooks dir (never committed) — almost
  # certainly a stale pointer into a different clone's default hooks
  # location. Otherwise it's an external directory that could be a
  # deliberate shared setup — leave it alone.
  case "$current_resolved" in
    */.git/*|*/.git)
      printf 'foreign-git-dir:%s:%s' "$current" "$current_resolved"
      return 0
      ;;
  esac

  printf 'third-party:%s:%s' "$current" "$current_resolved"
}

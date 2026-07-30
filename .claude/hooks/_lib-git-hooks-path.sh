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

# ------------------------------------------------------------------------
# _resolve_real_path PATH
#
# Resolves PATH to its canonical, symlink-free absolute form. Walks up to
# the nearest EXISTING ancestor, physically resolves it (`pwd -P`, which
# follows symlinks), then re-appends any not-yet-created tail literally —
# a tail that doesn't exist yet cannot itself be a symlink. This mirrors
# `realpath -m` without depending on GNU coreutils (not guaranteed present
# on macOS/BSD). Echoes the resolved path, or nothing if even "/" can't be
# stat'd (should not happen for a well-formed absolute path).
#
# Copied verbatim from require-active-ticket.sh's _resolve_real_path (see
# that file for the fuller symlink-bypass rationale) rather than sourcing
# it directly — that hook's copy carries ticket-gate-specific comments and
# the two call sites shouldn't share a lifecycle.
# ------------------------------------------------------------------------
_resolve_real_path() {
  local p="$1" dir tail=""
  [ -n "$p" ] || return 0
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
    return 0
  fi
  if [ -d "$dir" ]; then
    dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  else
    local parent
    parent="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)"
    if [ -n "$parent" ]; then
      dir="$parent/$(basename "$dir")"
    else
      dir=""
    fi
  fi
  [ -n "$dir" ] || return 0
  if [ -n "$tail" ]; then
    printf '%s/%s' "$dir" "$tail"
  else
    printf '%s' "$dir"
  fi
}

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

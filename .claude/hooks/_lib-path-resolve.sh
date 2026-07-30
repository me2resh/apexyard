#!/bin/bash
# _lib-path-resolve.sh — single shared implementation of the portable
# "realpath -m without GNU coreutils" helper used across the trust chain.
#
# Sourced by:
#   - require-active-ticket.sh (the ticket gate's symlink-safe path check)
#   - _lib-git-hooks-path.sh (used by bin/install-git-hooks.sh and
#     .claude/hooks/check-git-hooks-installed.sh)
#
# Why this file exists (PR #1087 review, Rex finding #4): the installer
# PR originally shipped its OWN copy of this function with a comment
# claiming it was "copied verbatim ... rather than sourcing it directly."
# That is exactly the AgDR-0113 pattern the #1086 arc exists to retire —
# an agreement asserted in a comment instead of enforced by one shared
# definition, in the very PR whose stated purpose is replacing
# command-text-matching duplication with structured ground truth. There
# is now exactly ONE _resolve_real_path in the codebase; every caller
# sources this file rather than embedding its own copy.
#
# NOT the same thing as _lib-portfolio-paths.sh's `_portfolio_canonicalize`.
# That function solves a related but distinct problem (portfolio-path
# resolution across split-portfolio mode) and has deliberately different
# semantics — it carries Windows drive-letter normalisation (#1018) and
# fails SOFT (echoes the input unchanged when unresolvable), where this
# function fails EMPTY (echoes nothing). Do not fold the two together;
# `_portfolio_canonicalize`'s callers rely on its fail-soft behaviour.

# Resolve PATH to its canonical, symlink-free absolute form. Walks up to
# the nearest EXISTING ancestor, physically resolves it (`pwd -P`, which
# follows symlinks), then re-appends any not-yet-created tail literally —
# a tail that doesn't exist yet cannot itself be a symlink. This mirrors
# `realpath -m` without depending on GNU coreutils (not guaranteed present
# on macOS/BSD). Echoes the resolved path, or nothing if even "/" can't be
# stat'd (should not happen for a well-formed absolute path).
#
# Why this matters (#883): without resolving symlinks first, a symlink
# living under $HOME that POINTS INTO a governed tree (e.g.
# ~/link-into-repo → the ops fork) would compare as "outside" the repo
# under a naive string-prefix check, silently bypassing the gate.
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

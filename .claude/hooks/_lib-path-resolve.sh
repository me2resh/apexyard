#!/bin/bash
# _lib-path-resolve.sh — shared nearest-existing-ancestor path helper used
# across the trust chain. It does not fully resolve final-component links.
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

# Resolve directory links in PATH without depending on GNU coreutils.
# Walk up to the nearest existing ancestor, physically resolve its directory
# (`pwd -P` follows links), then append the remaining tail literally.
# A final file symlink or dangling link can remain unresolved. Callers that
# grant a path-based exemption must check the target for symlinks separately.
# Echo the resulting path, or nothing if even "/" cannot be stat'd.
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
    # When the nearest existing ancestor is the filesystem root, it already
    # ends in `/`; do not add a second separator. This keeps every resolved
    # absolute path in canonical single-slash form.
    case "$dir" in
      /) printf '/%s' "$tail" ;;
      *) printf '%s/%s' "$dir" "$tail" ;;
    esac
  else
    printf '%s' "$dir"
  fi
}

# Map a Windows drive-letter path to one POSIX form.
# C:/Users/a b/repo and C:\Users\a b\repo both become /c/Users/a b/repo
# when cygpath is absent.
# A POSIX path is unchanged. A drive-relative path such as C:foo is unchanged.
# It is not absolute.
#
# Git Bash mounts C:/Users/<user>/AppData/Local/Temp at /tmp.
# pwd -P prints /tmp for that directory.
# The string transform prints /c/Users/.../Temp.
# Those two strings are one directory (me2resh/apexyard#1743).
# When cygpath is on PATH, a drive-letter path uses `cygpath -u --`.
# The function keeps that output when it is not empty and starts with /.
# When that directory exists, the function resolves it with pwd -P.
# Use the string transform when cygpath is absent.
# Use it when cygpath exits non-zero, prints nothing, or prints a path that
# does not start with /. That fallback does not call pwd -P.
# The function does not call cygpath for a path that already starts with /.
# Linux and macOS do not ship cygpath. Those hosts keep the string transform.
# The same string rule is in _portfolio_canonicalize (me2resh/apexyard#1018).
_windows_path_to_posix() {
  local p="$1" drive rest converted="" phys=""
  [ -n "$p" ] || return 0
  case "$p" in
    [A-Za-z]:/*|[A-Za-z]:\\*)
      if command -v cygpath >/dev/null 2>&1; then
        converted=$(cygpath -u -- "$p" 2>/dev/null) || converted=""
        case "$converted" in
          /*)
            if [ -d "$converted" ]; then
              phys=$(cd "$converted" 2>/dev/null && pwd -P) || phys=""
              if [ -n "$phys" ]; then
                converted="$phys"
              fi
            fi
            printf '%s' "$converted"
            return 0
            ;;
        esac
      fi
      drive="${p%%:*}"
      rest="${p#*:}"
      rest="$(printf '%s' "$rest" | tr '\\' '/')"
      drive="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
      printf '/%s%s' "$drive" "$rest"
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}

# Return 0 when CANDIDATE is ROOT or a path under ROOT.
# Both sides pass through _windows_path_to_posix first.
# An empty side is not contained.
# A failed conversion that leaves the /c/Users/.../Temp form does not match
# a pwd -P result under /tmp. The check rejects that pair.
# This rejects a prefix trick such as /repo-evil under /repo.
path_is_under_root() {
  local root="$1" candidate="$2"
  root=$(_windows_path_to_posix "$root")
  candidate=$(_windows_path_to_posix "$candidate")
  [ -n "$root" ] && [ -n "$candidate" ] || return 1
  case "$candidate" in
    "$root"|"$root"/*) return 0 ;;
  esac
  return 1
}

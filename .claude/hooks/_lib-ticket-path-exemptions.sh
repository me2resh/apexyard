#!/bin/bash
# Shared meta / docs path exemptions for the ticket-first gates.
#
# require-active-ticket.sh and require-migration-ticket.sh must agree on
# which paths skip the ticket marker. Match exemptions against the edited
# file's OWN git toplevel (linked worktree top), not the main-clone root
# that AgDR-0141 keeps for ops-root / marker resolution (AgDR-0219 / #1531).
#
# Usage:
#   . "$(dirname "$0")/_lib-ticket-path-exemptions.sh"
#   ticket_path_is_meta_exempt "$FILE_PATH"            # active-ticket shape
#   ticket_path_is_meta_exempt "$FILE_PATH" migration # also *.example
#
# Returns 0 when the path is meta/docs-exempt (no ticket required).
# Returns 1 when the caller must continue through the ticket gate.

# Nearest existing ancestor of a path (handles not-yet-created files).
_ticket_path_existing_dir() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
    dir=$(dirname "$dir")
  done
  [ -d "$dir" ] && printf '%s' "$dir"
}

# Physically resolve PATH for prefix compares (/var vs /private/var on macOS).
# Prefer shared _resolve_real_path when already sourced; else a local fallback.
_ticket_path_canonicalize() {
  local p="$1" joined="" dir=""
  [ -n "$p" ] || return 0

  case "$p" in
    /*) joined="$p" ;;
    *) joined="${PWD%/}/$p" ;;
  esac

  # Prefer the shared resolver. It can be a stub that prints nothing (the
  # gates define one when _lib-path-resolve.sh is missing), so an empty
  # answer falls through to the local fallback below instead of dropping
  # every exemption.
  if command -v _resolve_real_path >/dev/null 2>&1; then
    local resolved=""
    resolved=$(_resolve_real_path "$joined")
    if [ -n "$resolved" ]; then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  # Local fallback: resolve the deepest existing directory physically and
  # keep every component below it, including directories that do not exist
  # yet. Dropping them would collapse .claude/worktrees/<new>/src/a.ts to
  # .claude/a.ts and make it exempt.
  local anc="" rest="" real_anc=""
  anc=$(_ticket_path_existing_dir "$(dirname "$joined")")
  if [ -n "$anc" ]; then
    real_anc=$(cd "$anc" 2>/dev/null && pwd -P) || real_anc=""
  fi
  if [ -z "$real_anc" ]; then
    printf '%s' "$joined"
    return 0
  fi
  rest="${joined#"$anc"}"
  rest="${rest#/}"
  if [ "$real_anc" = "/" ]; then
    printf '/%s' "$rest"
  else
    printf '%s/%s' "$real_anc" "$rest"
  fi
}

# Own worktree top for FILE_PATH. Does NOT rewrite linked worktrees to the
# main clone (that rewrite stays in the ops-root path only — AgDR-0141).
# Pass "canonical" as the second argument when FILE_PATH is already
# canonicalized, to skip a second resolution.
ticket_path_own_toplevel() {
  local file_path="$1" canon="" fp_dir="" own_root=""
  [ -n "$file_path" ] || return 0

  if [ "${2:-}" = "canonical" ]; then
    canon="$file_path"
  else
    canon=$(_ticket_path_canonicalize "$file_path")
  fi
  [ -n "$canon" ] || return 0
  fp_dir=$(_ticket_path_existing_dir "$(dirname "$canon")")
  if [ -n "$fp_dir" ]; then
    own_root=$(git -C "$fp_dir" rev-parse --show-toplevel 2>/dev/null) || own_root=""
  fi
  if [ -n "$own_root" ] && [ -d "$own_root" ]; then
    own_root=$(cd "$own_root" 2>/dev/null && pwd -P) || true
  fi
  printf '%s' "$own_root"
}

# Match meta / docs exemptions for one write target.
ticket_path_is_meta_exempt() {
  local file_path="$1"
  local mode="${2:-}"
  local canon="" own_root="" rel="" stripped=0

  [ -n "$file_path" ] || return 1

  canon=$(_ticket_path_canonicalize "$file_path")
  [ -n "$canon" ] || return 1
  own_root=$(ticket_path_own_toplevel "$canon" canonical)
  rel="$canon"

  if [ -n "$own_root" ]; then
    case "$canon" in
      "$own_root"/*)
        rel="${canon#"$own_root"/}"
        stripped=1
        ;;
      "$own_root")
        rel="."
        stripped=1
        ;;
    esac
  fi

  if [ "$stripped" = "1" ]; then
    # Path is relative to the file's OWN tree. Do not use absolute
    # */.claude/* arms — those would re-exempt `.claude/worktrees/.../src`.
    # Nothing under .claude/worktrees/ is exempt as .claude/ content: a
    # path there that still strips against this tree is a worktree that
    # does not exist yet, is broken, or was cut short by target extraction
    # (a space in the path). Only *.md files there stay exempt.
    case "$rel" in
      .claude/worktrees/*|*/.claude/worktrees/*)
        case "$rel" in
          *.md) return 0 ;;
        esac
        return 1
        ;;
    esac
    case "$rel" in
      .claude/*|.claude|*/.claude/*|*/.claude) return 0 ;;
      docs/*|docs|*/docs/*|*/docs) return 0 ;;
      TODO.md|README.md|MEMORY.md|CLAUDE.md) return 0 ;;
    esac
    case "$rel" in
      *.md) return 0 ;;
    esac
    if [ "$mode" = "migration" ]; then
      case "$rel" in
        *.example) return 0 ;;
      esac
    fi
    return 1
  fi

  # Not stripped: keep today's absolute arms for out-of-repo paths and
  # any absolute spelling that never got a tree root (projects/*/docs under
  # a non-git tree is covered here via */docs/*).
  case "$canon" in
    */.claude/worktrees/*)
      case "$canon" in
        *.md) return 0 ;;
      esac
      return 1
      ;;
  esac
  case "$canon" in
    */.claude/*|*/.claude|*/docs/*|*/docs) return 0 ;;
    TODO.md|README.md|MEMORY.md|CLAUDE.md) return 0 ;;
    *.md) return 0 ;;
  esac
  if [ "$mode" = "migration" ]; then
    case "$canon" in
      *.example) return 0 ;;
    esac
  fi
  return 1
}

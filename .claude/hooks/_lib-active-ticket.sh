#!/bin/bash
# Shared active-ticket marker resolver.
#
# Both require-active-ticket.sh and require-migration-ticket.sh must ask the
# same question: which marker governs this target? Keeping the path, project,
# and tier-0 worktree rules here prevents the migration gate from drifting from
# the ordinary ticket gate.
# shellcheck disable=SC2088

_at_resolve_path() {
  local target="$1" base lexical resolved
  [ -n "$target" ] || return 0

  case "$target" in
    '~')    target="$HOME" ;;
    '~/'*)  target="$HOME/${target#\~/}" ;;
    '~'*)   return 0 ;;
  esac

  case "$target" in
    /*) ;;
    *)
      base=$(pwd -P 2>/dev/null) || return 0
      target="$base/$target"
      ;;
  esac

  # Collapse dot segments before the realpath-style pass. The latter must
  # preserve an absent tail verbatim, so lexical cleanup belongs first.
  lexical=$(printf '%s' "$target" | awk -F/ '{
    n = 0
    for (i = 1; i <= NF; i++) {
      if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n > 0) n--; continue }
      out[++n] = $i
    }
    s = ""
    for (i = 1; i <= n; i++) s = s "/" out[i]
    print (s == "" ? "/" : s)
  }')

  if command -v _resolve_real_path >/dev/null 2>&1; then
    resolved=$(_resolve_real_path "$lexical")
  else
    resolved="$lexical"
  fi
  [ -n "$resolved" ] || resolved="$lexical"
  case "$resolved" in
    //*) resolved="/${resolved#//}" ;;
  esac
  printf '%s' "$resolved"
}

_at_anchor() {
  local raw="$1" resolved=""
  [ -n "$raw" ] || return 0
  if command -v _resolve_real_path >/dev/null 2>&1; then
    resolved=$(_resolve_real_path "$raw")
  fi
  [ -n "$resolved" ] || resolved="$raw"
  printf '%s' "$resolved"
}

_at_project_for_resolved_path() {
  local path="$1" project="" tail ws ops
  ws=$(_at_anchor "${WORKSPACE_DIR:-}")
  ops=$(_at_anchor "${OPS_ROOT:-}")
  if [ -n "$ws" ]; then
    case "$path" in
      "$ws"/*) tail="${path#"$ws"/}"; project="${tail%%/*}" ;;
    esac
  fi
  if [ -z "$project" ] && [ -n "$ops" ]; then
    case "$path" in
      "$ops"/workspace/*) tail="${path#"$ops"/workspace/}"; project="${tail%%/*}" ;;
    esac
  fi
  printf '%s' "$project"
}

active_ticket_resolve_path() {
  _at_resolve_path "$1"
}

active_ticket_project_for_path() {
  local resolved
  resolved=$(_at_resolve_path "$1")
  [ -n "$resolved" ] || return 0
  _at_project_for_resolved_path "$resolved"
}

_at_existing_dir() {
  local dir="$1"
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
    dir=$(dirname "$dir")
  done
  [ -d "$dir" ] && printf '%s' "$dir"
}

active_ticket_marker_for_path() {
  local raw="$1" resolved project marker="" wt safe dir gd gcd
  resolved=$(_at_resolve_path "$raw")
  local home="${MARKER_HOME:-${OPS_ROOT:-${REPO_ROOT:-.}}}"
  # #1396: an empty $resolved has two distinct causes, and they must NOT
  # reach the ops-level fallback the same way.
  #
  #   1. $raw was ALSO empty. The caller passed an unextractable Bash write
  #      target (bash_extract_write_targets couldn't parse it, or the tool
  #      call carried no file_path at all). There is no path anywhere to
  #      gate on, so the ops-level current-ticket fallback below still
  #      runs and an active session ticket gates the write (the #1396 fix).
  #   2. $raw was NON-empty but still failed to resolve -- a `~user/`,
  #      `~+/` or `~-/` target. `_at_resolve_path` refuses those on
  #      purpose: their expansion depends on the caller shell or the
  #      passwd database, neither of which this hook can observe safely.
  #      This target names a SPECIFIC, real path this hook just can't
  #      read; it must return an EMPTY marker here, exactly like it did
  #      before the #1396 fix, so the migration gate still refuses it
  #      instead of falling through to whichever ticket happens to be
  #      active for a DIFFERENT project (H1 on PR #1404, restores #1159's
  #      fail-closed guarantee for this spelling).
  #
  # The project and per-worktree tiers below both depend on a resolved
  # path (there is no project to look up otherwise), so they are
  # naturally skipped whenever `project` stays empty.
  if [ -n "$resolved" ]; then
    project=$(_at_project_for_resolved_path "$resolved")
  fi

  if [ -n "$project" ]; then
    wt="${CLAUDE_WORKTREE_BRANCH:-}"
    if [ -z "$wt" ]; then
      dir=$(_at_existing_dir "$(dirname "$resolved")")
      gd=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)
      gcd=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
      if [ -n "$gd" ] && [ "$gd" != "$gcd" ]; then
        wt=$(git -C "$dir" branch --show-current 2>/dev/null)
      fi
    fi
    if [ -n "$wt" ]; then
      safe="${wt//\//__}"
      marker="$home/.claude/session/tickets/$project/$safe"
      [ -f "$marker" ] || marker=""
    fi
  fi

  if [ -z "$marker" ] && [ -n "$project" ] && [ -f "$home/.claude/session/tickets/$project" ]; then
    marker="$home/.claude/session/tickets/$project"
  # Cause 2 above (a non-empty $raw that failed to resolve) must NOT reach
  # this fallback -- that is the H1 fix. The guard is "resolved is
  # non-empty" (an ordinary path with no matching project, dev's existing
  # behavior) OR "$raw was empty" (cause 1, the #1396 fix).
  elif [ -z "$marker" ] && { [ -n "$resolved" ] || [ -z "$raw" ]; } \
    && [ -f "$home/.claude/session/current-ticket" ]; then
    marker="$home/.claude/session/current-ticket"
  fi
  printf '%s' "$marker"
}

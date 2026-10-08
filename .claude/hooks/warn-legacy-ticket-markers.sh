#!/bin/bash
# SessionStart hook: tell the agent that old-layout ticket markers exist.
#
# Ticket markers are moving to each working tree's git dir (AgDR-0222). During
# the move, old files under <ops_root>/.claude/session/ are still read wherever
# they were read before, and /start-ticket still writes them. This hook prints
# one informational notice at session start when an old file exists that no
# new marker for the same tree shadows, so the agent knows both layouts are
# live. SessionStart stdout goes
# into the agent's context, so the notice reaches the agent whether or not a
# later edit is blocked.
#
# Advisory only. It always exits 0, prints nothing when no old file exists,
# and never deletes or moves a file.

set -u

# The hook input is not needed.
if [ ! -t 0 ]; then cat >/dev/null 2>&1 || true; fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
if [ -f "$HOOK_DIR/_lib-ops-root.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-ops-root.sh"
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  ROOT=$(resolve_ops_root "${REPO_ROOT:-$PWD}")
fi
[ -n "$ROOT" ] || exit 0

SESSION_DIR="$ROOT/.claude/session"

# An old file is shadowed when the tree it stands for holds a trusted new
# marker: the ops fork for current-ticket, the project's clone for
# tickets/<name>, and that clone's linked worktree on <branch> for
# tickets/<name>/<branch>. A shadowed file changes nothing, so the notice
# leaves it out. Without the resolver every old file is listed.
HAVE_LIB=0
if [ -f "$HOOK_DIR/_lib-active-ticket.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-active-ticket.sh"
  active_ticket_init "$ROOT" >/dev/null 2>&1 && HAVE_LIB=1
fi
# has_new <tree>: true when <tree> holds a trusted new marker
has_new() {
  [ "$HAVE_LIB" = 1 ] || return 1
  [ -d "$1" ] || return 1
  active_ticket_lookup "$1" && [ "$AT_SOURCE" = tree ]
}
# wt_for <clone> <safe-branch>: prints the linked worktree of <clone> on the branch
wt_for() {
  local g h b
  for g in "$1/.git/worktrees"/*/; do
    [ -f "$g/HEAD" ] && [ -f "$g/gitdir" ] || continue
    IFS= read -r h < "$g/HEAD" || continue
    b="${h#ref: refs/heads/}"
    [ "$b" != "$h" ] || continue
    if [ "${b//\//__}" = "$2" ]; then
      IFS= read -r h < "$g/gitdir" || continue
      printf '%s' "${h%/.git}"
      return 0
    fi
  done
  return 1
}
shadowed() {
  local f="$1" rel name br clone wt
  [ "$HAVE_LIB" = 1 ] || return 1
  rel="${f#"$SESSION_DIR"/}"
  case "$rel" in
    current-ticket) has_new "$ROOT" ;;
    tickets/*/*)
      rel="${rel#tickets/}"
      name="${rel%%/*}"
      br="${rel#*/}"
      active_ticket_project_clone "$name" || return 1
      clone="$REPLY"
      wt=$(wt_for "$clone" "$br") || return 1
      has_new "$wt"
      ;;
    tickets/*)
      name="${rel#tickets/}"
      active_ticket_project_clone "$name" || return 1
      has_new "$REPLY"
      ;;
    *) return 1 ;;
  esac
}

found=""
if [ -f "$SESSION_DIR/current-ticket" ] && ! shadowed "$SESSION_DIR/current-ticket"; then
  found="$SESSION_DIR/current-ticket"
fi
if [ -d "$SESSION_DIR/tickets" ]; then
  for f in "$SESSION_DIR/tickets"/* "$SESSION_DIR/tickets"/*/*; do
    [ -f "$f" ] || continue
    shadowed "$f" && continue
    found="${found:+$found, }$f"
  done
fi
[ -n "$found" ] || exit 0

printf "apexyard: ticket markers are moving to each working tree's git dir. Old markers under .claude/session/ are still read and written during the move. A marker in a tree's git dir wins over an old one. Found: %s. See AgDR-0222.\n" "$found"
exit 0

#!/bin/bash
# Prepare one worktree for a /fan-out writer task.
#
# Usage: prepare-worktree.sh <source-tree> <worktree-path> <branch> [<repo> <number> <title> <url>]
#
#   <source-tree>    The working tree the task belongs to. A task on a managed
#                    project uses workspace/<name>/. A task on the ops fork
#                    uses the ops root. The worktree is created from this
#                    tree, never from another repo.
#   <worktree-path>  Where the new linked worktree goes. It must not exist.
#   <branch>         The new branch for the worktree.
#   ticket fields    Optional. Without them, the script copies the ticket of
#                    <source-tree> (its repo, number, title and url).
#
# The script writes the ticket marker into the git dir of the new worktree,
# through the shared resolver, so the ticket gate lets the writer agent edit.
# It also writes the old-layout per-worktree marker, so a hook from before the
# move sees the ticket too.
# When the new worktree fails validation, only the old-layout marker is
# written, with a one-line note. If neither marker is written, the script
# removes the worktree and the branch it created. It never uses --force.
#
# On success it prints the worktree path. On failure it prints the reason to
# stderr and exits non-zero.

set -u

# The caller's git environment must not choose the repository, the index, the
# object store or the config that the git calls below act on. The four
# variables that pick the repository go first, so the scrub holds when git is
# missing or fails. Then git's own list of repository-local variables goes,
# which also covers GIT_OBJECT_DIRECTORY, GIT_CONFIG_PARAMETERS and the rest.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
_git_local_env=$(git rev-parse --local-env-vars 2>/dev/null) || _git_local_env=""
for _git_var in $_git_local_env; do
  case "$_git_var" in
    GIT_*) case "$_git_var" in *[!A-Z0-9_]*) ;; *) unset "$_git_var" ;; esac ;;
  esac
done
unset _git_local_env _git_var

SOURCE="${1:-}"
WTPATH="${2:-}"
BRANCH="${3:-}"
if [ -z "$SOURCE" ] || [ -z "$WTPATH" ] || [ -z "$BRANCH" ]; then
  echo "usage: prepare-worktree.sh <source-tree> <worktree-path> <branch> [<repo> <number> <title> <url>]" >&2
  exit 2
fi
REPO="${4:-}"
NUMBER="${5:-}"
TITLE="${6:-}"
URL="${7:-}"

HOOK_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
if [ ! -f "$HOOK_DIR/_lib-active-ticket.sh" ]; then
  echo "prepare-worktree: _lib-active-ticket.sh not found next to the hooks" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-active-ticket.sh"

if [ -e "$WTPATH" ]; then
  echo "prepare-worktree: $WTPATH already exists" >&2
  exit 1
fi

if ! active_ticket_init "$SOURCE"; then
  echo "prepare-worktree: cannot resolve the ops root for $SOURCE" >&2
  exit 1
fi

# The source tree must hold a ticket when the caller gave none. The ticket may
# be the marker in its git dir or an old-layout marker.
if [ -z "$NUMBER" ]; then
  if ! active_ticket_lookup "$SOURCE"; then
    echo "prepare-worktree: no active ticket for $SOURCE. Run /start-ticket there first." >&2
    exit 1
  fi
  marker="$REPLY"
  active_ticket_read_field "$marker" repo && REPO="$REPLY"
  active_ticket_read_field "$marker" number && NUMBER="$REPLY"
  active_ticket_read_field "$marker" title && TITLE="$REPLY"
  active_ticket_read_field "$marker" url && URL="$REPLY"
  if [ -z "$REPO" ] || [ -z "$NUMBER" ]; then
    echo "prepare-worktree: the ticket marker of $SOURCE has no repo= or number=" >&2
    exit 1
  fi
fi

if ! git -C "$SOURCE" worktree add -q "$WTPATH" -b "$BRANCH" 2>/dev/null; then
  echo "prepare-worktree: git worktree add failed for $WTPATH on branch $BRANCH" >&2
  exit 1
fi

_at_memo_clear
wrote=0
if active_ticket_gitdir "$WTPATH"; then
  _at_memo_clear
  active_ticket_write "$WTPATH" "$REPO" "$NUMBER" "$TITLE" "$URL" "$BRANCH" && wrote=1
else
  echo "prepare-worktree: note: $WTPATH failed validation (${AT_REASON:-unknown}), so only the old-layout marker is written" >&2
fi
# A repo outside the registry maps to the session-level old-layout marker. An
# existing one belongs to the session that started the fan-out, so keep it.
# The old /fan-out flow relied on that file in the same way.
if active_ticket_legacy_path "$WTPATH" "$REPO"; then
  if [ "$AT_LEGACY_KIND" = session ] && [ -e "$REPLY" ]; then
    echo "prepare-worktree: note: kept the existing $REPLY" >&2
    wrote=1
  else
    active_ticket_write_legacy "$WTPATH" "$REPO" "$NUMBER" "$TITLE" "$URL" "$BRANCH" && wrote=1
  fi
fi
if [ "$wrote" = 0 ]; then
  echo "prepare-worktree: no marker was written, so the worktree is removed" >&2
  git -C "$SOURCE" worktree remove "$WTPATH" >/dev/null 2>&1 || true
  git -C "$SOURCE" branch -d "$BRANCH" >/dev/null 2>&1 || true
  exit 1
fi

printf '%s\n' "$WTPATH"

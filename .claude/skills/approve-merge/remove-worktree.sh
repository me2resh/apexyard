#!/bin/bash
# Offer and perform the removal of a merged PR's linked worktree.
#
# Usage:
#   remove-worktree.sh list   <source-tree> <merged-head-branch>
#   remove-worktree.sh remove <source-tree> <worktree-path> <merged-head-branch>
#
#   <source-tree>  The local clone of the PR's repo: workspace/<name>/ for a
#                  managed project, or the ops root for an ops fork PR. The
#                  resolver validates it, and every git call runs with -C on
#                  its validated common dir.
#
# list    Prints one line per linked worktree that holds the merged branch:
#           ok<TAB><path>
#           refused (<reason>)<TAB><path>
#         then the ignored files of each ok worktree, indented by two spaces.
#         The skill shows that list in its confirmation prompt.
# remove  Removes one worktree after the user has said yes. It re-checks that
#         git still lists the path, that the worktree still holds the merged
#         head branch, and every refusal rule below. A detached worktree is
#         refused. The skill passes the head branch of the PR it just merged.
#         The helper does not check the merge itself, because a squash merge
#         leaves no ancestry that git can see. It runs `git worktree remove`
#         with no --force, so a dirty worktree stops the step and is reported.
#
# Candidates come only from `git worktree list --porcelain -z`, which needs
# git 2.36 or later. An older git rejects -z. The list is then empty, so the
# script exits 1 and removes nothing. The script
# refuses the main worktree, a locked worktree, the session's own tree, and any
# path that equals or contains the ops root. It never deletes a path itself.

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

MODE="${1:-}"
SOURCE="${2:-}"
ARG="${3:-}"
MERGED_BRANCH="${4:-}"
if [ -z "$MODE" ] || [ -z "$SOURCE" ] || [ -z "$ARG" ] \
  || { [ "$MODE" = remove ] && [ -z "$MERGED_BRANCH" ]; }; then
  echo "usage: remove-worktree.sh list <source-tree> <branch> | remove <source-tree> <path> <branch>" >&2
  exit 2
fi

HOOK_DIR="$(cd "$(dirname "$0")/../../hooks" && pwd)"
if [ ! -f "$HOOK_DIR/_lib-active-ticket.sh" ]; then
  echo "remove-worktree: _lib-active-ticket.sh not found next to the hooks" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-active-ticket.sh"

active_ticket_init "$SOURCE" || { echo "remove-worktree: cannot resolve the ops root for $SOURCE" >&2; exit 1; }
if ! active_ticket_gitdir "$SOURCE"; then
  echo "remove-worktree: $SOURCE is not a valid working tree: ${AT_REASON:-git dir failed validation}" >&2
  exit 1
fi
COMMON="$_AT_MC"
OPS="$_AT_OPS"
[ -n "$COMMON" ] && [ -n "$OPS" ] || { echo "remove-worktree: no validated common dir" >&2; exit 1; }
OPS_REAL=$(cd -P "$OPS" 2>/dev/null && pwd)
SESSION_TREE=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$SESSION_TREE" ] || SESSION_TREE=$(cd -P "$SESSION_TREE" 2>/dev/null && pwd)

# Parse the porcelain output into parallel arrays: path, branch ref, locked.
WT_PATHS=()
WT_BRANCH=()
WT_LOCKED=()
cur_path=""
cur_branch=""
cur_locked=0
flush() {
  if [ -n "$cur_path" ]; then
    WT_PATHS+=("$cur_path")
    WT_BRANCH+=("$cur_branch")
    WT_LOCKED+=("$cur_locked")
  fi
  cur_path=""
  cur_branch=""
  cur_locked=0
}
# -z ends each field with a NUL, so a path with a newline stays one field.
# git before 2.36 has no -z here and fails, which leaves the list empty.
while IFS= read -r -d '' line; do
  case "$line" in
    "worktree "*) flush; cur_path="${line#worktree }" ;;
    "branch "*) cur_branch="${line#branch }" ;;
    "locked"*) cur_locked=1 ;;
    "") ;;
  esac
done < <(git -C "$COMMON" worktree list --porcelain -z 2>/dev/null)
flush

if [ "${#WT_PATHS[@]}" -eq 0 ]; then
  echo "remove-worktree: git listed no worktree for $SOURCE" >&2
  exit 1
fi

# refusal_for <index>: prints the reason to refuse, or nothing
refusal_for() {
  local i="$1" p real
  p="${WT_PATHS[$i]}"
  real=$(cd -P "$p" 2>/dev/null && pwd)
  [ -n "$real" ] || { echo "path is missing"; return; }
  # Without the session tree and the ops root, the own-tree and ops-root checks
  # cannot run, so every candidate is refused.
  if [ -z "$SESSION_TREE" ] || [ -z "$OPS_REAL" ]; then echo "cannot tell the session's own tree or the ops root"; return; fi
  [ "$i" != 0 ] || { echo "main worktree"; return; }
  [ "${WT_LOCKED[$i]}" != 1 ] || { echo "locked"; return; }
  [ -z "$SESSION_TREE" ] || [ "$real" != "$SESSION_TREE" ] || { echo "the session's own tree"; return; }
  case "$OPS_REAL/" in
    "$real"/*) echo "equals or contains the ops root"; return ;;
  esac
}

case "$MODE" in
  list)
    found=0
    ignored=""
    total=0
    for i in "${!WT_PATHS[@]}"; do
      [ "${WT_BRANCH[$i]}" = "refs/heads/$ARG" ] || continue
      found=1
      why=$(refusal_for "$i")
      if [ -n "$why" ]; then
        printf 'refused (%s)\t%s\n' "$why" "${WT_PATHS[$i]}"
      else
        printf 'ok\t%s\n' "${WT_PATHS[$i]}"
        ignored=$(git -C "${WT_PATHS[$i]}" ls-files --others --ignored --exclude-standard 2>/dev/null)
        if [ -n "$ignored" ]; then
          printf '%s\n' "$ignored" | head -n 20 | sed 's/^/  /'
          total=$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')
          if [ "$total" -gt 20 ]; then printf '  ... and %s more ignored files\n' "$((total - 20))"; fi
        fi
      fi
    done
    [ "$found" = 1 ] || echo "none: no linked worktree holds branch $ARG"
    exit 0
    ;;
  remove)
    for i in "${!WT_PATHS[@]}"; do
      [ "${WT_PATHS[$i]}" = "$ARG" ] || continue
      if [ "${WT_BRANCH[$i]}" != "refs/heads/$MERGED_BRANCH" ]; then
        echo "remove-worktree: refused, the worktree does not hold the merged branch $MERGED_BRANCH: $ARG" >&2
        exit 1
      fi
      why=$(refusal_for "$i")
      if [ -n "$why" ]; then
        echo "remove-worktree: refused, $why: $ARG" >&2
        exit 1
      fi
      if git -C "$COMMON" worktree remove "$ARG"; then
        echo "removed $ARG"
        exit 0
      fi
      echo "remove-worktree: git did not remove $ARG. It may hold changes. Review it, then remove it yourself." >&2
      exit 1
    done
    echo "remove-worktree: $ARG is not a linked worktree of $SOURCE" >&2
    exit 1
    ;;
  *)
    echo "remove-worktree: unknown mode $MODE" >&2
    exit 2
    ;;
esac

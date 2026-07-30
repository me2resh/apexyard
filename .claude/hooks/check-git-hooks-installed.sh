#!/bin/bash
# check-git-hooks-installed.sh — SessionStart advisory: warns when this
# clone's core.hooksPath is unset, points at a non-existent directory, or
# points at a stale leftover from a different clone, so the tracked
# .githooks/pre-push hook silently never runs on a terminal `git push`.
#
# Part of me2resh/apexyard#1086 step 1. Same advisory shape as
# check-upstream-drift.sh and check-jq-installed.sh: non-blocking, exit 0
# always. The banner cannot force the fix — it removes the "nobody knew
# this clone's terminal pushes were unprotected" failure mode.
#
# Silent exit paths (no output, no error):
#   - Not a git repo
#   - No tracked hooks dir (default: .githooks) in this repo at all — a
#     managed-project clone that hasn't adopted ApexYard's git hooks yet
#     is not a misconfiguration, just nothing to advise on
#   - core.hooksPath already resolves correctly ("correct" classification)
#   - The shared detection lib is missing (older fork pre-#1086; nothing
#     to check against)
#
# Banner fires only for the three states install-git-hooks.sh's own README
# documents as fixable: unset, missing (non-existent target dir), and
# foreign-git-dir (stale pointer into a different clone) or a third-party
# directory the classify lib can't confirm is deliberate.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  exit 0
fi

cd "$REPO_ROOT" || exit 0

HOOKS_DIR_NAME=".githooks"

# Nothing tracked to install in this repo — silent. (Most managed-project
# workspace clones today; the ops fork always carries .githooks/.)
if [ ! -d "$REPO_ROOT/$HOOKS_DIR_NAME" ]; then
  exit 0
fi

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOOK_DIR/_lib-git-hooks-path.sh"
if [ ! -f "$LIB" ]; then
  exit 0
fi
# shellcheck source=/dev/null
. "$LIB"

STATE=$(ghp_classify "$REPO_ROOT" "$HOOKS_DIR_NAME")

case "$STATE" in
  correct)
    exit 0
    ;;

  unset)
    cat >&2 <<MSG
ApexYard: core.hooksPath is unset in this clone — the tracked git pre-push
hook isn't installed. A terminal \`git push\` won't run the tracked check
set, only Claude-Code-driven pushes will. Run:
  bash bin/install-git-hooks.sh
MSG
    ;;

  missing:*)
    RAW="${STATE#missing:}"
    cat >&2 <<MSG
ApexYard: core.hooksPath is set to '$RAW', which doesn't exist — the
tracked git hook here is silently inert. Run:
  bash bin/install-git-hooks.sh
MSG
    ;;

  foreign-git-dir:*)
    REST="${STATE#foreign-git-dir:}"
    RAW="${REST%%:*}"
    cat >&2 <<MSG
ApexYard: core.hooksPath is set to '$RAW' — looks like a stale pointer into
a different clone's .git directory. The tracked git hook here is silently
inert. Run:
  bash bin/install-git-hooks.sh
MSG
    ;;

  third-party:*)
    REST="${STATE#third-party:}"
    RAW="${REST%%:*}"
    cat >&2 <<MSG
ApexYard: core.hooksPath is set to '$RAW', a directory that isn't this
repo's tracked $HOOKS_DIR_NAME. If that's deliberate, ignore this — see
bash bin/install-git-hooks.sh --help if you want to review or change it.
MSG
    ;;
esac

exit 0

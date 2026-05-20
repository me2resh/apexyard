#!/bin/bash
# Blocks direct pushes and commits to long-lived integration branches.
# All changes must go through pull requests.
#
# Protected branches (default): main / master / dev / develop.
# `dev` was added in apexyard#116 (release-cut model — see AgDR-0007). Forks
# that legitimately use `dev` as a daily-work trunk under their own
# convention can override the protected list via
# `.claude/project-config.json` → `.git.protected_branches[]`.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Resolve protected-branch list from project config (shared reader, #109).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
PROTECTED=""
if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/.claude/hooks/_lib-read-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$REPO_ROOT/.claude/hooks/_lib-read-config.sh"
  PROTECTED=$(config_get '.git.protected_branches[]' 2>/dev/null | paste -sd'|' -)
fi
if [ -z "$PROTECTED" ]; then
  PROTECTED="main|master|dev|develop"
fi

# Block: git push <remote> <protected>
if echo "$COMMAND" | grep -qE "\bgit\s+push\s+\S+\s+(${PROTECTED})(\s|$)"; then
  cat >&2 <<MSG
BLOCKED: Cannot push directly to a protected branch.

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main"). Protected branches: ${PROTECTED//|/, }.

To unblock:
  1. Create a feature branch from your current work:
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Push the feature branch:
       git push -u origin feature/GH-<ticket>-<short-description>
  3. Open a PR via /feature → /start-ticket → gh pr create, OR if the
     ticket exists, just: gh pr create --base <protected-branch> --head <feature-branch>

Customise (rare): .claude/project-config.json → .git.protected_branches[]
REPLACES the default list (main / master / dev / develop). To REMOVE
protection from a default-protected branch (e.g. you legitimately use
'dev' as your trunk), write the array with that branch OMITTED. To ADD
protection to a new branch, write the array INCLUDING it. The hook
trusts whichever list you provide — get the direction right.
MSG
  exit 2
fi

# Block: git commit on a protected branch
if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
  if [ -n "$CURRENT_BRANCH" ] && echo "$CURRENT_BRANCH" | grep -qE "^(${PROTECTED})$"; then
    cat >&2 <<MSG
BLOCKED: Cannot commit directly on protected branch '$CURRENT_BRANCH'.

All changes must go through a PR (.claude/rules/git-conventions.md
§ "No Direct Main").

To unblock:
  1. Create a feature branch from your current state (preserves your
     in-progress edits):
       git checkout -b feature/GH-<ticket>-<short-description>
  2. Retry the commit on the feature branch
  3. Push and open a PR when ready

If you've already committed locally to '$CURRENT_BRANCH' by accident,
the recovery is a three-step rescue (NOT a separate To-unblock — the
gate is still the one above): create a recovery branch pointing at the
current commit, reset $CURRENT_BRANCH to drop the accidental commit
locally, then check out the recovery branch.

       git branch feature/GH-<ticket>-recovery
       git reset --hard HEAD~1   # drops the commit from $CURRENT_BRANCH
       git checkout feature/GH-<ticket>-recovery
MSG
    exit 2
  fi
fi

exit 0

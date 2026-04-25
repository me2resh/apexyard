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
  echo "BLOCKED: Cannot push directly to a protected branch. All changes must go through a PR." >&2
  echo "Protected branches: ${PROTECTED//|/, }" >&2
  exit 2
fi

# Block: git commit on a protected branch
if echo "$COMMAND" | grep -qE '\bgit\s+commit\b'; then
  CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
  if [ -n "$CURRENT_BRANCH" ] && echo "$CURRENT_BRANCH" | grep -qE "^(${PROTECTED})$"; then
    echo "BLOCKED: Cannot commit directly on protected branch '$CURRENT_BRANCH'. Create a feature branch first." >&2
    exit 2
  fi
fi

exit 0

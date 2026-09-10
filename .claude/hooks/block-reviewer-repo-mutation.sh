#!/bin/bash
# CLASS: CONTROL — blocks repository-mutating git commands while a sanctioned
# review-class agent is active (me2resh/apexyard#1233, AgDR-0145).
#
# The active-reviewer marker is written by the review skill immediately before
# Rex, Hakim, or Tariq is spawned. It is a narrow session signal: when present,
# review-class work is in flight, so Bash git mutations must be rejected before
# they can alter the reviewed branch or working tree. Read-only git commands
# remain available for evidence gathering and review submission.

set -u

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

# If the hook cannot parse the tool payload, do not invent a block when there
# is no active review. With an active marker, fail closed for payloads that
# visibly contain a git mutation.
ROOT="${APEXYARD_REVIEW_OPS_ROOT:-}"
if [ -z "$ROOT" ] || [ ! -d "$ROOT/.claude/session" ]; then
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  while [ -n "$ROOT" ] && [ "$ROOT" != / ]; do
    if [ -f "$ROOT/.apexyard-fork" ] || { [ -f "$ROOT/onboarding.yaml" ] && [ -f "$ROOT/apexyard.projects.yaml" ]; }; then
      break
    fi
    ROOT=$(dirname "$ROOT")
  done
fi

[ -n "$ROOT" ] || exit 0
ACTIVE="$ROOT/.claude/session/active-reviewer"
[ -f "$ACTIVE" ] || exit 0

if [ -z "$COMMAND" ]; then
  if printf '%s' "$INPUT" | grep -qE '(^|[^[:alnum:]_-])git[[:space:]]+([^;&|]*[[:space:]])?(add|commit|push|restore|reset|stash|clean|checkout|switch|mv|rm|rebase|cherry-pick|merge|tag|branch)([[:space:];|&]|$)'; then
    echo "BLOCKED: review-class agent cannot mutate the repository while an active review is in flight; use read-only git commands and report findings." >&2
    exit 2
  fi
  exit 0
fi

# Remove confirmed heredoc bodies before inspecting command text. Review prose
# often mentions git verbs; only the command portion should be classified.
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if [ -f "$HOOK_DIR/_lib-strip-heredoc.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOK_DIR/_lib-strip-heredoc.sh"
  COMMAND=$(strip_heredoc_bodies "$COMMAND")
fi

# A git subcommand is mutating when it can change the index, worktree, refs, or
# remote. The command-position anchor avoids matching quoted review prose such
# as `echo 'git commit is forbidden'`. Options such as `git -C repo commit` are
# accepted by the middle token span.
MUTATING='add|commit|push|restore|reset|stash|clean|checkout|checkout-index|switch|mv|rm|rebase|cherry-pick|merge|tag|branch|update-ref|fetch|apply|submodule|worktree|notes|revert|am|bisect|config|reflog|replace|sparse-checkout|filter-branch|gc|init|repack|prune|fast-import|fast-export|pull|remote|read-tree|write-tree|commit-tree|update-index|hash-object|index-pack|pack-refs|mktag|mktree|rerere|maintenance|clone|init-db|stage|subtree|replay|format-patch|archive'
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\\|\\||;|\\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?(${MUTATING})([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent is read-only while an active review is in flight. Do not stage, commit, push, restore, stash, or otherwise mutate the repository; report the finding to the orchestrator." >&2
  exit 2
fi

exit 0

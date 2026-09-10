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
MUTATING='add|commit|push|restore|reset|stash|clean|checkout|checkout-index|switch|mv|rm|rebase|cherry-pick|merge|tag|update-ref|fetch|apply|submodule|revert|am|bisect|replace|sparse-checkout|filter-branch|gc|init|repack|prune|fast-import|fast-export|pull|read-tree|write-tree|commit-tree|update-index|hash-object|index-pack|pack-refs|mktag|mktree|rerere|maintenance|clone|init-db|stage|subtree|replay|format-patch'

# `git remote get-url` and `git remote -v` are read-only operations used to
# resolve the review host. Block only remote subcommands that change remotes.
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?remote[[:space:]]+(add|remove|set-url|rename|prune|update|set-branches|set-head)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent is read-only while an active review is in flight. Do not mutate repository remotes; report the finding to the orchestrator." >&2
  exit 2
fi

# These commands have read-only subcommands that reviewers use for evidence;
# block their write-capable forms while preserving the read forms.
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?branch([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git[[:space:]]+branch([[:space:]]*$|[[:space:]]+(-a|--all|--show-current|--list|-l|-r|--remotes|-v|-vv|--verbose|--contains|--merged|--no-merged|--points-at|--format=|--sort=|--column|--color))"; then
  echo "BLOCKED: review-class agent cannot create or alter branches during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?config([[:space:]]|$)" && \
   ! printf '%s' "$COMMAND" | grep -qE "git[[:space:]]+config[[:space:]]+(-{1,2}(get|get-all|get-regexp|list|show-origin|show-scope|name-only|includes|null)([[:space:]]|$)|-l([[:space:]]|$))"; then
  echo "BLOCKED: review-class agent cannot change Git configuration during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?reflog([[:space:]]|$)([^;&|]*[[:space:]])?(expire|delete|drop)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter reflogs during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?notes([[:space:]]|$)([^;&|]*[[:space:]])?(add|append|copy|edit|merge|prune|remove|rewrite|strip)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter Git notes during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?worktree([[:space:]]|$)([^;&|]*[[:space:]])?(add|lock|move|prune|remove|repair|unlock)([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent cannot alter worktrees during an active review." >&2
  exit 2
fi
if printf '%s' "$COMMAND" | grep -qE "(^|&&|\\|\\||;|\\|)[[:space:]]*git[[:space:]]+([^;&|]*[[:space:]])?(${MUTATING})([[:space:];|&]|$)"; then
  echo "BLOCKED: review-class agent is read-only while an active review is in flight. Do not stage, commit, push, restore, stash, or otherwise mutate the repository; report the finding to the orchestrator." >&2
  exit 2
fi

exit 0

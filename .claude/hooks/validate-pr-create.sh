#!/bin/bash
# Validates PR creation:
# - PR title matches format: type(TICKET): description
# - PR body contains a Glossary section
# - Branch has a ticket ID
# - The ticket referenced in the title actually exists in the tracker repo
#   (backstop for the ticket-vocabulary rule — catches fabricated #N that
#   slipped through prose into a PR title)
#
# Customize the ticket pattern below if your team uses a different scheme.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Parse --repo from the gh command for cross-repo PR creation
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)

# Only check on gh pr create
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then
  exit 0
fi

ERRORS=""

# Extract --title value (macOS-compatible, no grep -P)
TITLE=$(echo "$COMMAND" | sed -n 's/.*--title[[:space:]]*["'"'"']\([^"'"'"']*\)["'"'"'].*/\1/p' | head -1)
if [ -z "$TITLE" ]; then
  TITLE=$(echo "$COMMAND" | sed -n 's/.*--title[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
fi

# Validate PR title format if we can extract it
# Accepts: type(<TICKET>): … or type(<TICKET>)!: … (breaking change)
# The !? makes the breaking-change marker optional per Conventional Commits 1.0.
# Note: this pattern is intentionally aligned with the pr-title-check.yml
# CI workflow regex so anything that passes this hook also passes CI.
TICKET_REF=""
if [ -n "$TITLE" ]; then
  if ! echo "$TITLE" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)\(([A-Z]{2,10}-[0-9]+|#[0-9]+)\)!?:'; then
    ERRORS="${ERRORS}PR title '$TITLE' doesn't match format: type(TICKET-ID): description\n"
  else
    # Extract the ticket reference so we can verify it exists
    TICKET_REF=$(echo "$TITLE" | sed -nE 's/^[a-z]+\(([^)]+)\):.*/\1/p')
  fi
fi

# Verify the ticket in the title actually exists in the tracker repo
# (backstop for ticket-vocabulary.md — catches fabricated #N in PR titles)
if [ -n "$TICKET_REF" ]; then
  # Extract digits from the ref (works for both #N and PREFIX-N)
  TICKET_NUM=$(echo "$TICKET_REF" | grep -oE '[0-9]+$')

  # Resolve tracker repo: prefer --repo flag, then project-config.json, then origin
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
  TRACKER_REPO=""
  if [ -n "$CMD_REPO" ]; then
    TRACKER_REPO="$CMD_REPO"
  elif [ -f "${REPO_ROOT}/.claude/project-config.json" ]; then
    TRACKER_REPO=$(jq -r '.tracker_repo // empty' "${REPO_ROOT}/.claude/project-config.json" 2>/dev/null)
  fi
  if [ -z "$TRACKER_REPO" ]; then
    # Parse owner/repo from origin remote
    ORIGIN_URL=$(git remote get-url origin 2>/dev/null)
    TRACKER_REPO=$(echo "$ORIGIN_URL" | sed -nE 's|.*[:/]([^/:]+/[^/]+)\.git$|\1|p; s|.*[:/]([^/:]+/[^/]+)$|\1|p' | head -1)
  fi

  if [ -n "$TICKET_NUM" ] && [ -n "$TRACKER_REPO" ]; then
    # Fetch both number and state in one call so we can distinguish
    # "does not exist" from "exists but CLOSED". Both are blocking.
    ISSUE_JSON=$(gh issue view "$TICKET_NUM" --repo "$TRACKER_REPO" --json number,state 2>/dev/null)
    if [ -z "$ISSUE_JSON" ]; then
      cat >&2 <<MSG
BLOCKED: PR title references ${TICKET_REF} but issue #${TICKET_NUM} does not
exist in ${TRACKER_REPO}.

This is the failure mode the ticket-vocabulary rule exists to prevent — do NOT
use tracker notation (#N) for plan items that have no real issue behind them.
See .claude/rules/ticket-vocabulary.md § "The rule".

If you intended to create the PR for a real ticket, verify the number.
If you were about to file work that has no ticket yet, create one first:
  gh issue create --repo ${TRACKER_REPO} --title "..."
and use the returned number in your PR title.
MSG
      exit 2
    fi

    ISSUE_STATE=$(echo "$ISSUE_JSON" | jq -r '.state // empty' 2>/dev/null)
    if [ "$ISSUE_STATE" = "CLOSED" ]; then
      cat >&2 <<MSG
BLOCKED: PR title references ${TICKET_REF} but issue #${TICKET_NUM} in
${TRACKER_REPO} is CLOSED.

Every PR needs its own OPEN ticket. Referencing a closed issue means the PR
has no live acceptance criteria, no QA handoff, and no tracker row to move
through the SDLC states — the ticket is already Done.

Common causes:
  - The work is a follow-up to the closed issue → create a NEW ticket that
    describes the follow-up, link back to the closed one in the body, and
    use the new number in the PR title.
  - The closed issue was auto-closed by a prior PR that didn't fully finish
    the work → re-open it (gh issue reopen ${TICKET_NUM} --repo ${TRACKER_REPO})
    or create a new ticket for the remaining work.
  - The number is a typo → fix the PR title.

See .claude/rules/ticket-vocabulary.md and the "every PR needs its own open
ticket" feedback in memory.
MSG
      exit 2
    fi
  fi
fi

# Check PR body for Glossary section
if echo "$COMMAND" | grep -q '\-\-body'; then
  if ! echo "$COMMAND" | grep -qiE '##\s*(Glossary|glossary)'; then
    ERRORS="${ERRORS}PR body missing required '## Glossary' section.\n"
  fi
fi

# Validate branch name has ticket ID
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ]; then
  if ! echo "$CURRENT_BRANCH" | grep -qE '[A-Z]{2,10}-[0-9]+|GH-[0-9]+|#[0-9]+'; then
    ERRORS="${ERRORS}Branch '$CURRENT_BRANCH' missing ticket ID.\n"
  fi
fi

if [ -n "$ERRORS" ]; then
  echo "PR VALIDATION BLOCKED:" >&2
  printf "$ERRORS" >&2
  echo "" >&2
  echo "Fix the issues above before creating the PR." >&2
  echo "See .claude/rules/git-conventions.md and .claude/rules/pr-quality.md." >&2
  exit 2
fi

exit 0

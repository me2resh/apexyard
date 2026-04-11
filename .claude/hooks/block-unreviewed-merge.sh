#!/bin/bash
# PreToolUse hook on `gh pr merge`: blocks merging a PR that has no recorded
# Rex (code-reviewer) approval.
#
# Enforces workflow-gates rule #5 ("2 reviews — agent + human, CI green,
# commit SHA matches review") at the merge boundary, mechanically. An approval
# is a file at .claude/session/reviews/<pr>-rex.approved whose contents are
# the SHA Rex reviewed. If Rex requests changes, no file is written and merge
# stays blocked until a follow-up review passes.
#
# Human approver sign-off is still required in addition to this check — the
# hook just guarantees you can't merge without the agent review.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check on gh pr merge
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+merge\b'; then
  exit 0
fi

# Extract PR number: either from the command args or from the current branch's PR.
# Handles both `gh pr merge 42` and flag-first forms like `gh pr merge --auto 42`.
PR_NUMBER=$(echo "$COMMAND" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*' | grep -oE '[0-9]+' | head -1)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null)
fi

if [ -z "$PR_NUMBER" ]; then
  echo "BLOCKED: Could not determine PR number for merge. Run from a PR branch or pass an explicit PR number." >&2
  exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
APPROVAL="${REPO_ROOT:-.}/.claude/session/reviews/${PR_NUMBER}-rex.approved"

if [ ! -f "$APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has no recorded code-reviewer (Rex) approval.

ApexStack requires two reviews before merge (workflow-gates rule #5):
  1. Code Reviewer agent (Rex) — automated, recorded in .claude/session/reviews/
  2. Human approver (Tech Lead / CEO / project owner) — recorded on the PR

Expected approval file does not exist:
  ${APPROVAL}

To unblock:
  1. Invoke the code-reviewer agent on this PR
  2. When Rex returns "approved", record it:
       mkdir -p .claude/session/reviews
       echo "<commit-sha>" > .claude/session/reviews/${PR_NUMBER}-rex.approved
  3. Retry the merge

Never skip this check — even for typo fixes. See workflow-gates rule #5.
MSG
  exit 2
fi

# Commit SHA consistency: make sure the approved SHA matches current HEAD.
# A review is bound to a specific commit — new commits after review invalidate it.
APPROVED_SHA=$(tr -d '[:space:]' < "$APPROVAL")
CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null)
if [ -n "$APPROVED_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$APPROVED_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: Code-reviewer approved commit ${APPROVED_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after review. Re-invoke Rex on the latest HEAD before merging.
MSG
  exit 2
fi

exit 0

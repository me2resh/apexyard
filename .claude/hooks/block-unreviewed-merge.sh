#!/bin/bash
# PreToolUse hook on `gh pr merge`: blocks merging a PR that does not have
# BOTH required approval markers in place.
#
# Enforces workflow-gates rule #5 ("2 reviews — agent + human, CI green,
# commit SHA matches review") at the merge boundary, mechanically. Two
# markers are required:
#
#   .claude/session/reviews/<pr>-rex.approved
#     Written by the code-reviewer agent (Rex) after a successful review.
#     Contents: the commit SHA Rex reviewed.
#
#   .claude/session/reviews/<pr>-ceo.approved
#     Written ONLY by the /approve-merge <pr> skill on explicit user
#     invocation. Contents: the commit SHA the CEO approved.
#
# Both markers must exist, and both SHAs must match the live HEAD. Any
# commits pushed after approval invalidate both — re-review and re-approve.
#
# The CEO marker is the mechanical enforcement of the "plan-level 'go' is
# NOT merge approval" rule in .claude/rules/pr-workflow.md. An umbrella
# "go" on a plan does not produce this file — only the /approve-merge
# skill does, and the skill is defined to run only on explicit user
# invocation that names the PR.
#
# Claude can technically forge either marker by running `touch` or `echo`
# directly. Doing so is a visible, auditable, grep-able rule violation
# and is itself a hard stop. The point of mechanical enforcement is to
# turn invisible inference failures into visible rule violations.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only check on gh pr merge
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+merge\b'; then
  exit 0
fi

# Parse --repo from the command for cross-repo merge operations
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
REPO_FLAG=""
if [ -n "$CMD_REPO" ]; then
  REPO_FLAG="--repo $CMD_REPO"
fi

# Extract PR number: either from the command args or from the current branch's PR.
# Handles both `gh pr merge 42` and flag-first forms like `gh pr merge --auto 42`.
PR_NUMBER=$(echo "$COMMAND" | grep -oE '\bgh\s+pr\s+merge\b[^|;&]*' | grep -oE '[0-9]+' | head -1)
if [ -z "$PR_NUMBER" ]; then
  PR_NUMBER=$(gh pr view $REPO_FLAG --json number --jq '.number' 2>/dev/null)
fi

if [ -z "$PR_NUMBER" ]; then
  echo "BLOCKED: Could not determine PR number for merge. Run from a PR branch or pass an explicit PR number." >&2
  exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
REVIEWS_DIR="${REPO_ROOT:-.}/.claude/session/reviews"
REX_APPROVAL="${REVIEWS_DIR}/${PR_NUMBER}-rex.approved"
CEO_APPROVAL="${REVIEWS_DIR}/${PR_NUMBER}-ceo.approved"
CURRENT_SHA=$(git rev-parse HEAD 2>/dev/null)

# --- Rex marker check ---
if [ ! -f "$REX_APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has no recorded code-reviewer (Rex) approval.

ApexStack requires two reviews before merge (workflow-gates rule #5):
  1. Code Reviewer agent (Rex) — automated, recorded in .claude/session/reviews/
  2. Human approver (CEO) — recorded by the /approve-merge skill

Missing file:
  ${REX_APPROVAL}

To unblock:
  1. Invoke the code-reviewer agent on this PR
  2. When Rex returns "approved", it records the approval automatically
  3. Then run /approve-merge ${PR_NUMBER} for the CEO approval
  4. Retry the merge

Never skip this check — even for typo fixes. See .claude/rules/pr-workflow.md.
MSG
  exit 2
fi

REX_SHA=$(tr -d '[:space:]' < "$REX_APPROVAL")
if [ -n "$REX_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$REX_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: Code-reviewer approved commit ${REX_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the Rex review. Re-invoke Rex on the latest
HEAD before merging.
MSG
  exit 2
fi

# --- CEO marker check ---
if [ ! -f "$CEO_APPROVAL" ]; then
  cat >&2 <<MSG
BLOCKED: PR #${PR_NUMBER} has Rex approval but no CEO approval marker.

Plan-level "go" / "continue" / "ship it" does NOT authorize a merge. Each
merge requires an explicit per-PR, per-merge CEO approval that names the
PR. See .claude/rules/pr-workflow.md § "Plan-level 'go' is NOT merge
approval" for the full rationale.

Missing file:
  ${CEO_APPROVAL}

To unblock:
  1. Stop and ask the CEO explicitly: "PR #${PR_NUMBER} ready to merge — approved?"
  2. When the CEO says "approved" / "merge it" / "ship it" naming PR #${PR_NUMBER},
     invoke the /approve-merge skill:
       /approve-merge ${PR_NUMBER}
  3. The skill writes ${CEO_APPROVAL} with the current HEAD SHA
  4. Retry the merge

NEVER create this marker yourself from an umbrella "go" on a plan.
EVER. This is the exact failure this hook exists to prevent.
MSG
  exit 2
fi

CEO_SHA=$(tr -d '[:space:]' < "$CEO_APPROVAL")
if [ -n "$CEO_SHA" ] && [ -n "$CURRENT_SHA" ] && [ "$CEO_SHA" != "$CURRENT_SHA" ]; then
  cat >&2 <<MSG
BLOCKED: CEO approved commit ${CEO_SHA:0:7} but HEAD is now ${CURRENT_SHA:0:7}.

New commits were pushed after the CEO approval. Re-request CEO approval
via /approve-merge ${PR_NUMBER} on the new HEAD before merging.
MSG
  exit 2
fi

exit 0

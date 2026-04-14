#!/bin/bash
# PreToolUse hook on `gh pr merge` AND `gh api .../pulls/<N>/merge`: blocks
# merging a PR that does not have BOTH required approval markers in place.
#
# Both merge shapes are covered — see _lib-extract-pr.sh for the parser and
# #47 for why the API-shape bypass was a gap worth closing.
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

# Shared merge-shape detector + PR-number parser (see _lib-extract-pr.sh).
# Handles `gh pr merge <N>` and `gh api repos/<owner>/<repo>/pulls/<N>/merge`.
. "$(dirname "$0")/_lib-extract-pr.sh"

if ! is_merge_command "$COMMAND"; then
  exit 0
fi

# Parse --repo (for `gh pr merge --repo owner/repo`). The API-shape encodes
# the repo in its URL path so we don't need the flag there — downstream
# `gh pr view` / `gh pr checks` calls still benefit when the flag was passed.
CMD_REPO=$(echo "$COMMAND" | sed -nE 's/.*--repo[[:space:]]+([^[:space:]]+).*/\1/p' | head -1)
# If the command uses the API shape, recover owner/repo from the URL path
# so other gh calls below can still be scoped correctly.
if [ -z "$CMD_REPO" ]; then
  CMD_REPO=$(echo "$COMMAND" | grep -oE 'repos/[^/[:space:]]+/[^/[:space:]]+/pulls/[0-9]+/merge' | sed -nE 's|repos/([^/]+/[^/]+)/pulls/.*|\1|p' | head -1)
fi

PR_NUMBER=$(extract_pr_number "$COMMAND")

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

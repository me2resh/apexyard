#!/bin/bash
# PreToolUse advisory hook (exit 0 always) — fires when a Write tool call or
# a Bash command targets a *-rex.approved or *-ceo.approved file under
# .claude/session/reviews/.
#
# Purpose: remind build-class sub-agents (platform-engineer, backend-engineer,
# frontend-engineer, product-manager, etc.) that review markers must come from
# the real code-reviewer agent or the /approve-merge skill — NOT from the
# agent that just finished building the thing being reviewed.
#
# This hook NEVER blocks (exit 0 always). It is an advisory nudge, not a gate.
# The hard enforcement is in block-unreviewed-merge.sh, which requires a real
# posted GitHub review at HEAD in addition to the local marker file (#494).
#
# Wired in .claude/settings.json PreToolUse for:
#   matcher: Write    (catches direct file writes)
#   matcher: Bash     (catches shell redirections, printf, tee, etc.)
#
# See AgDR-0062 and .claude/rules/pr-workflow.md § "Build agents cannot
# self-review" for the design rationale.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

_is_marker_target() {
  local text="$1"
  # Match any path that ends with a review-marker filename pattern:
  #   *-rex.approved or *-ceo.approved
  # under a .claude/session/reviews/ directory.
  echo "$text" | grep -qE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo)\.approved'
}

MATCHED=0

case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if _is_marker_target "$FILE_PATH"; then
      MATCHED=1
    fi
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    if _is_marker_target "$COMMAND"; then
      MATCHED=1
    fi
    ;;
esac

if [ "$MATCHED" = "1" ]; then
  cat >&2 <<'BANNER'
[apexyard] ADVISORY: You are about to write a review marker under .claude/session/reviews/.

Review markers must only be written by:
  - The real code-reviewer agent (Rex) — writes *-rex.approved after posting
    a GitHub review on the PR
  - The /approve-merge skill — writes *-ceo.approved on explicit CEO approval

Build-class agents (backend-engineer, frontend-engineer, platform-engineer,
product-manager, etc.) MUST NOT write these files. A fabricated marker will
be rejected at merge time — block-unreviewed-merge.sh requires a real posted
GitHub review at HEAD in addition to the local marker file (#494).

If you are a build agent: report your results plainly and hand off to the
orchestrator. Do not self-review.
BANNER
fi

exit 0

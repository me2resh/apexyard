#!/bin/bash
# PreToolUse advisory hook (exit 0 always) — fires when a Write tool call or
# a Bash command targets a *-rex.approved or *-ceo.approved file under
# .apexyard/session/reviews/.
#
# Purpose: remind build-class sub-agents (platform-engineer, backend-engineer,
# frontend-engineer, product-manager, etc.) that review markers must come from
# the real code-reviewer agent or the /approve-merge skill — NOT from the
# agent that just finished building the thing being reviewed.
#
# This hook NEVER blocks (exit 0 always). It is an advisory nudge, not a gate.
# The real safety is the per-PR human CEO nod (via /approve-merge) plus the
# orchestrator running the independent review — NOT a mechanical lock. A stronger
# mechanical gate (requiring a posted, author-independent GitHub review at HEAD)
# is DEFERRED as a config opt-in for hands-off / multi-account setups (#494) —
# see AgDR-0062 for why it isn't on by default (single-account maintainers would
# be locked out).
#
# Wired in .claude/settings.json PreToolUse for:
#   matcher: Write    (catches direct file writes)
#   matcher: Bash     (catches shell redirections, printf, tee, etc.)
#
# See AgDR-0062 and .apexyard/rules/pr-workflow.md § "Build agents cannot
# self-review" for the design rationale.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

_is_marker_target() {
  local text="$1"
  # Match any path that ends with a review-marker filename pattern:
  #   *-rex.approved or *-ceo.approved
  # under a .apexyard/session/reviews/ directory.
  echo "$text" | grep -qE '\.apexyard/session/reviews/[^[:space:]"'"'"']+-(rex|ceo)\.approved'
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
[apexyard] ADVISORY: You are about to write a review marker under .apexyard/session/reviews/.

Review markers must only be written by:
  - The real code-reviewer agent (Rex) — writes *-rex.approved after posting
    a GitHub review on the PR
  - The /approve-merge skill — writes *-ceo.approved on explicit CEO approval

Build-class agents (backend-engineer, frontend-engineer, platform-engineer,
product-manager, etc.) MUST NOT write these files. The merge is gated by an
explicit human CEO nod (/approve-merge) and the orchestrator running the real,
independent review — a self-written marker substitutes for neither. (A
mechanical review-authenticity gate is a deferred opt-in — see AgDR-0062.)

If you are a build agent: report your results plainly and hand off to the
orchestrator. Do not self-review.
BANNER
fi

exit 0

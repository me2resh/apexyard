#!/bin/bash
# PreToolUse advisory hook (exit 0 always) — fires when a Write tool call or
# a Bash command targets a *-rex.approved or *-ceo.approved file under
# .claude/session/reviews/.
#
# PURPOSE
# -------
# Build-class sub-agents (platform-engineer, backend-engineer, frontend-engineer,
# product-manager, etc.) implementing a ticket CANNOT spawn the real code-reviewer
# (Rex) because they cannot nest the Agent tool.  If such an agent writes a
# *-rex.approved marker and frames its output as "Rex approved", it satisfies the
# merge gate's filename check without satisfying its INTENT — the author is
# reviewing its own work, defeating the two-reviews rule.
#
# This hook fires on every attempt to write a review marker and emits an
# UNMISSABLE banner to make the violation visible before the write lands.
#
# WHY THIS HOOK CANNOT BLOCK (#728)
# ----------------------------------
# A full mechanical block would require distinguishing the sanctioned
# code-reviewer agent from a build-class agent at the shell level.  In the
# current harness there is no per-agent-type env var (CLAUDE_AGENT_TYPE or
# similar) — all sub-agents share the same environment (CLAUDE_CODE_CHILD_SESSION
# is set for every sub-agent, not just build-class ones).  Without a reliable
# provenance signal the hook cannot block without also blocking the real Rex
# write.  Options for a future full block:
#
#   A) Harness emits CLAUDE_SUBAGENT_TYPE per sub-agent spawn → hook checks it.
#   B) Rex marker carries structured provenance fields (like the CEO marker's
#      approved_by=user / skill_version=2) that a build agent cannot fabricate
#      without also violating the structured-format check in block-unreviewed-merge.sh.
#
# Both options are deferred; a /decide AgDR should evaluate them.  In the
# meantime the primary safeguards remain: (1) this unmissable advisory banner,
# (2) the prompt-guardrail in each build-agent file, and (3) the per-PR human
# CEO nod required by /approve-merge.
#
# References: #728, AgDR-0062, .claude/rules/pr-workflow.md
#             § "Build agents cannot self-review"
#
# Wired in .claude/settings.json PreToolUse for:
#   matcher: Write    (catches direct file writes via the Write tool)
#   matcher: Bash     (catches shell redirections, echo >, printf, tee, etc.)

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

_is_marker_target() {
  local text="$1"
  # Match any path ending with a review-marker filename under the reviews dir:
  #   *-rex.approved  — Rex gate marker (written by code-reviewer after review)
  #   *-ceo.approved  — CEO gate marker (written by /approve-merge on explicit approval)
  echo "$text" | grep -qE '\.claude/session/reviews/[^[:space:]"'"'"']+-(rex|ceo)\.approved'
}

MATCHED=0
MARKER_TYPE=""

case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if _is_marker_target "$FILE_PATH"; then
      MATCHED=1
      # Identify which marker type for a more targeted message.
      echo "$FILE_PATH" | grep -q '\-rex\.approved' && MARKER_TYPE="rex"
      echo "$FILE_PATH" | grep -q '\-ceo\.approved' && MARKER_TYPE="ceo"
    fi
    ;;
  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    if _is_marker_target "$COMMAND"; then
      MATCHED=1
      echo "$COMMAND" | grep -q '\-rex\.approved' && MARKER_TYPE="rex"
      echo "$COMMAND" | grep -q '\-ceo\.approved' && MARKER_TYPE="ceo"
    fi
    ;;
esac

if [ "$MATCHED" = "1" ]; then
  # Determine the specific violation message based on which marker type.
  if [ "$MARKER_TYPE" = "rex" ]; then
    MARKER_RULE="*-rex.approved must be written ONLY by the real code-reviewer agent (Rex)
  after it posts a GitHub review on the PR.  Rex is a separate sub-agent with
  its own context — not the agent that just built the thing being reviewed."
    MARKER_WHO="Rex (code-reviewer sub-agent), invoked by the orchestrator via /code-review"
  elif [ "$MARKER_TYPE" = "ceo" ]; then
    MARKER_RULE="*-ceo.approved must be written ONLY by the /approve-merge skill
  on an explicit per-PR CEO approval.  It carries structured provenance fields
  (approved_by=user, skill_version=2) that cannot be fabricated casually."
    MARKER_WHO="/approve-merge skill, invoked by the orchestrator on an explicit CEO nod"
  else
    MARKER_RULE="Review markers must be written only by the real code-reviewer (Rex)
  or the /approve-merge skill — not by the agent that built the code."
    MARKER_WHO="the real code-reviewer (Rex) or /approve-merge"
  fi

  cat >&2 <<BANNER
======================================================================
[apexyard] VIOLATION WARNING: Unauthorized review-marker write detected
======================================================================

You are about to write a review marker under .claude/session/reviews/.

  ${MARKER_RULE}

  Who may write this marker:
    ${MARKER_WHO}

WHY THIS MATTERS
  Writing this file yourself satisfies the merge gate's FILENAME check
  but NOT its INTENT.  The two-reviews rule (workflow-gates #5 /
  pr-workflow § "Build agents cannot self-review") requires the reviewer
  to be a SEPARATE agent with independent context.  A build-class agent
  (backend/frontend/platform engineer, product-manager, etc.) is the
  AUTHOR — it cannot be its own independent reviewer.

  The merge gate hook (block-unreviewed-merge.sh) will accept a forged
  marker and let an unreviewed PR through.  This is a silent bypass of
  the safety gate the framework exists to enforce.

IF YOU ARE A BUILD-CLASS AGENT — STOP
  Do NOT write this file.
  Do NOT frame your output as a "Rex review" or "APPROVED" verdict.
  Report your build results plainly (what you built, tests run/passed).
  Hand off to the orchestrator — it will run the real Rex review.

IF YOU ARE THE CODE-REVIEWER (Rex) — PROCEED WITH CAUTION
  This banner is advisory.  You are the sanctioned writer.  Verify you
  have posted a real GitHub review comment on the PR before writing the
  marker.  (A mechanical write-block for this case requires harness-level
  provenance — see #728 and AgDR-0062 for the deferred design.)

======================================================================
BANNER
fi

exit 0

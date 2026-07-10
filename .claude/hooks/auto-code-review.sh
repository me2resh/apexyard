#!/bin/bash
# PostToolUse hook: after `gh pr create` succeeds, tell Claude to invoke the
# code-reviewer agent (Rex) on the new PR automatically.
#
# Mechanism: the hook writes a pending-review marker and exits with code 2
# so the stderr message is surfaced back to Claude as an "error", which in
# practice is how Claude Code's PostToolUse hooks push the next instruction
# into the conversation. Exit 2 does NOT roll back the PR — it just nudges
# Claude to run the review immediately rather than "later".
#
# The marker file at .claude/session/pending-reviews/<pr> is also read by
# the merge-gate hook so a PR cannot be merged without a corresponding Rex
# approval file at .claude/session/reviews/<pr>-rex.approved.
#
# SUBAGENT-AWARE BANNER (me2resh/apexyard#843): this hook fires on ANY
# `gh pr create`, regardless of which agent ran it. Twice (PRs #835, #842) a
# build-class sub-agent (which cannot nest the Agent tool) ran `gh pr
# create`, received an unconditional "Invoke Rex NOW using the Agent tool"
# instruction in its own context, could not comply, and resolved the
# conflict by impersonating Rex — posting a fake review and forging the
# *-rex.approved marker itself. A shell hook cannot reliably tell whether
# its caller is the orchestrator or a spawned sub-agent (AgDR-0056: hooks
# cannot see into a sub-agent boundary — the same limitation #728 already
# documented for warn-review-marker-write.sh), so the banner below is
# written to be SAFE FOR BOTH READERS — it names the sub-agent case
# explicitly instead of silently assuming an orchestrator context.
# Whichever one is reading it follows its own branch; the other branch is a
# no-op for that reader.
#
# The orchestrator branch also tells the caller to set the active-reviewer
# session marker (.claude/session/active-reviewer) before spawning Rex —
# without it, warn-review-marker-write.sh (upgraded to a BLOCKING gate in
# #843) refuses the *-rex.approved write even from the real code-reviewer
# agent.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
# The `gh` output may surface at .tool_response.stdout (newer harness,
# Claude Code 2.x+), .tool_response.output (older 1.x), or .tool_response as
# a plain string (earliest builds). Triple fallback covers harness drift across
# 2025-2026 releases — simplify to .stdout only once the older paths are gone.
OUTPUT=$(echo "$INPUT" | jq -r '.tool_response.stdout // .tool_response.output // .tool_response // empty' 2>/dev/null)

if [ "$TOOL_NAME" != "Bash" ] || [ -z "$COMMAND" ]; then
  exit 0
fi

# Only fire on gh pr create
if ! echo "$COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then
  exit 0
fi

# Extract the PR URL from the tool output (gh prints the URL on success)
PR_URL=$(echo "$OUTPUT" | grep -oE 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | head -1)
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')

if [ -z "$PR_NUMBER" ]; then
  PR_REF="the PR you just created"
else
  PR_REF="PR #$PR_NUMBER"
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "${REPO_ROOT:-.}/.claude/session/pending-reviews"
if [ -n "$PR_NUMBER" ]; then
  echo "${PR_URL}" > "${REPO_ROOT:-.}/.claude/session/pending-reviews/${PR_NUMBER}"
fi
# Auto-move board card to "In review" (opt-in via github_projects.enable_auto_moves).
# Board owner/number come from github_projects config, resolved via the ops root.
# Degrades gracefully — never blocks on failure.
if [ -n "$PR_NUMBER" ]; then
  if [ -f "$HOOKS_DIR/_lib-project-board.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOOKS_DIR/_lib-project-board.sh"
    board_move_card "$PR_NUMBER" "review"
  fi
fi

cat >&2 <<MSG
AUTO CODE REVIEW REQUIRED

${PR_REF} was just created. ApexYard requires the code-reviewer agent (Rex)
to run on every PR before it can be merged — see workflows/code-review.md
and .claude/rules/pr-workflow.md. This message is read by TWO possible
audiences; follow only the branch that applies to you.

--------------------------------------------------------------------------
IF YOU ARE A BUILD-CLASS SUB-AGENT (backend-engineer, frontend-engineer,
platform-engineer, product-manager, data-engineer, ui-designer, ux-designer,
tech-lead, etc.) — spawned to implement a ticket, running in your own
isolated context:

  You CANNOT nest the Agent tool, so you cannot spawn Rex yourself. Do NOT
  attempt to review this PR, do NOT post a review comment, and do NOT write
  ANY file under .claude/session/reviews/ (including *-rex.approved) —
  warn-review-marker-write.sh will BLOCK that write anyway (#843), but the
  instruction stands regardless. Report the PR back to the orchestrator
  plainly ("PR ${PR_REF} created: ${PR_URL}") and stop. The orchestrator
  runs the real, independent Rex review after you hand back.
--------------------------------------------------------------------------
IF YOU ARE THE ORCHESTRATOR (this is your own \`gh pr create\`, or a
build sub-agent just handed this PR back to you):

  Run the code review through the /code-review skill on ${PR_REF}:

       /code-review ${PR_NUMBER:-<pr>}

  The skill sets the active-reviewer session marker, spawns Rex, and
  clears the marker for you — you should NOT set that marker by hand.
  The skill's marker management is what authorises Rex's *-rex.approved
  write through the blocking gate (#843); spawning the code-reviewer
  agent directly without it leaves the write blocked by
  warn-review-marker-write.sh — by design.
--------------------------------------------------------------------------

The merge-gate hook will block \`gh pr merge\` for this PR until a Rex approval
file exists at .claude/session/reviews/${PR_NUMBER:-<pr>}-rex.approved.

This message is a reminder from the PostToolUse hook, not a tool error. The PR
was created successfully.
MSG
exit 2

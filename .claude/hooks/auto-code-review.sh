#!/bin/bash
# PostToolUse hook: after `gh pr create` succeeds, tell Claude to run the
# code-reviewer agent (Rex) on the new PR.
#
# Mechanism: the hook writes a pending-review marker and exits with code 2
# so the stderr message is surfaced back to Claude as an "error", which in
# practice is how Claude Code's PostToolUse hooks push the next instruction
# into the conversation. Exit 2 does NOT roll back the PR — it just nudges
# Claude to run the review immediately rather than "later".
#
# The marker file at .claude/session/pending-reviews/<pr> is also read by
# the merge-gate hook so a PR cannot be merged without a corresponding Rex
# approval file at .claude/session/reviews/<owner>__<repo>__<pr>-rex.approved
# (repo-qualified, AgDR-0060). This banner deliberately does NOT print that
# path: quoting a literal marker path at an agent is the #1144 vector — the
# reviewer obeys the path it is handed instead of resolving its own, and the
# marker lands bare-number where no gate reads it. Name the review, never the
# path.
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
# The banner uses one short line, capped at 300 bytes. It tells the
# orchestrator to wait for CI, then run /code-review. Sub-agents report
# the PR to the orchestrator. It gives no marker instructions or tier note.
#
# TIER-AWARE NOTE (me2resh/apexyard#1064, AgDR-0116): this header keeps
# "Rex runs on every PR" completely unconditional. The merge gate requires
# Rex approval for every tier. The tier-aware role chain includes the
# Security Auditor, Solution Architect, and UI Designer when their triggers apply.
# The review rules set Rex's depth. The banner does not describe those rules.

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
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCAN_COMMAND="$COMMAND"
if [ -r "$HOOKS_DIR/_lib-command-scrub.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOKS_DIR/_lib-command-scrub.sh"
  SCAN_COMMAND=$(scrub_bash_command "$COMMAND")
fi
if ! echo "$SCAN_COMMAND" | grep -qE '\bgh\s+pr\s+create\b'; then
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

# Banner budget: 300 bytes at most (me2resh/apexyard#1625, tested by
# test_auto_code_review_banner.sh). The long text lived here before and cost
# about 3.9 KB of context on every PR. The rules it carried are in
# .claude/rules/pr-workflow.md and the /code-review skill. Keep both readers
# covered (#843): a build agent cannot spawn Rex and must not review.
# The caller class comes from the harness agent_type (review_caller_class in
# _lib-review-markers.sh, AgDR-0145 amendment, me2resh/apexyard#1649). A
# sub-agent gets the stop line and the orchestrator gets the review line.
# With no class available, print the combined line that serves both readers.
CALLER_CLASS=unknown
if [ -r "$HOOKS_DIR/_lib-review-markers.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOKS_DIR/_lib-review-markers.sh"
  CALLER_CLASS=$(review_caller_class "$INPUT" "")
fi
case "$CALLER_CLASS" in
  reviewer|other-agent|untyped-agent)
    printf '%s\n' "${PR_REF} created. Report the PR and stop. Never review it or write review markers. The orchestrator runs the review." >&2
    ;;
  main)
    printf '%s\n' "${PR_REF} created. Wait for green CI with a Monitor, then run /code-review ${PR_NUMBER:-<pr>}. Build agents run at the same time." >&2
    ;;
  *)
    printf '%s\n' "${PR_REF} created. Build agent: report the PR and stop; never review it or write review markers. Orchestrator: wait for green CI with a Monitor, then run /code-review ${PR_NUMBER:-<pr>}." >&2
    ;;
esac
exit 2

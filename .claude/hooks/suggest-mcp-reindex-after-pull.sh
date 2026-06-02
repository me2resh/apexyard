#!/bin/bash
# PostToolUse hook: prompts an MCP reindex after a workspace/<name>/ managed-
# project clone is UPDATED via git (pull / fetch+merge / merge / checkout that
# moves HEAD / reset --hard).
#
# Why this exists
# ---------------
# Companion to suggest-mcp-reindex-after-clone.sh (#475 closes the post-CLONE
# gap). This hook closes the post-UPDATE gap (#478): when a workspace clone's
# code drifts because the agent pulled new commits, nothing reindexes that
# project. search_code then returns stale-or-not_indexed results and the agent
# silently falls back to grep + Read.
#
# The high-signal trigger is `git pull` inside a workspace clone. We also fire
# on the other HEAD-moving shapes (`git merge`, `git checkout <branch>`,
# `git reset --hard`, and a `git fetch` that the agent follows with a merge) so
# the reminder is not limited to the single happy path.
#
# Trigger granularity decision (AgDR-0058)
# ----------------------------------------
# This fires on a git HEAD-move, NOT on per-file Edit/Write. Per-edit reindex
# prompts would be far too noisy (one banner per save) and the staleness they'd
# flag is negligible — a single edited file barely moves the index. A pull, by
# contrast, can rewrite the whole tree in one step, which is exactly the moment
# the index goes meaningfully stale. So the trigger is scoped to the coarse,
# high-signal event.
#
# Behaviour
# ---------
#   - Fires on PostToolUse Bash where the command is a HEAD-moving git op AND
#     the working location is a workspace/<name>/ clone. The working location
#     is detected from (in priority order):
#       1. the payload `.cwd` (the harness-provided cwd for the Bash call), or
#          `.tool_input.cwd` if the harness nests it there;
#       2. an explicit `-C <path>` argument in the command;
#       3. a `cd workspace/<name> && git pull`-style prefix in the command;
#       4. any bare workspace/<name> path token in the command.
#     cwd-based detection (1) is the common case — a `git pull` is normally run
#     from INSIDE the clone with no path argument. It depends on the harness
#     populating cwd in the PostToolUse payload; (2)-(4) are the fallbacks when
#     it doesn't.
#   - Scopes the reindex suggestion to the CHANGED project only (parsed
#     `<name>`), never the whole portfolio.
#   - Emits a single advisory banner to stderr naming the reindex call.
#   - Exits 0 always — advisory, non-blocking. Same shape as
#     suggest-mcp-reindex-after-clone.sh / check-upstream-drift.sh.
#   - Silent no-op when:
#       * The command isn't a HEAD-moving git op in a workspace clone
#       * The command failed (tool_response.exit_code != 0)
#       * The pull changed nothing — output contains "Already up to date."
#         (debounce; see tradeoff note below)
#
# Debounce tradeoff
# -----------------
# A `git pull` that changed nothing ("Already up to date.") is suppressed when
# that string is visible in the tool output. When the output isn't available
# (or the change came via merge/checkout/reset with no such marker) the hook
# fires anyway. Over-firing a cheap advisory is acceptable; under-firing
# defeats the purpose — a real drift that goes un-reindexed produces silent
# stale search results, which is the failure mode #478 exists to prevent.
#
# Banner budget: <= 600 chars (this hook emits ~300 chars when it fires).
#
# Tests at .claude/hooks/tests/test_suggest_mcp_reindex_after_pull.sh.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Only consider HEAD-moving git operations. A `git fetch` on its own does NOT
# move HEAD, but agents commonly run `git fetch ... && git merge ...` — that
# compound command contains `git merge`, so it's caught by the merge branch.
# A bare `git fetch` is intentionally NOT matched.
#
# The `git` token must sit at a COMMAND boundary (start, or after a shell
# separator `&& || ; | (`) — optionally as `git -C <path>` — so a literal
# `grep "git pull" .` argument doesn't false-match. The op verb follows
# immediately (after an optional `-C <path>` / `--git-dir <path>` global flag).
if ! echo "$COMMAND" | grep -qE '(^|&&|\|\||;|\||\()[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+|--git-dir[=[:space:]][^[:space:]]+[[:space:]]+)*(pull|merge|checkout|reset)\b'; then
  exit 0
fi

# Skip if the prior tool call failed — don't suggest reindex on a git op that
# errored. PostToolUse input carries tool_response.exit_code on Bash.
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0' 2>/dev/null)
if [ "${EXIT_CODE:-0}" != "0" ]; then
  exit 0
fi

# Debounce: if the tool output shows the pull changed nothing, don't nag.
# Inspect the common output carriers; tolerate whichever the harness uses.
RESPONSE_TEXT=$(echo "$INPUT" | jq -r '
  [ (.tool_response.stdout // empty),
    (.tool_response.stderr // empty),
    (.tool_response.output // empty),
    (.tool_response | if type=="string" then . else empty end) ]
  | join("\n")' 2>/dev/null)
if echo "$RESPONSE_TEXT" | grep -qF 'Already up to date.'; then
  exit 0
fi

# ------------------------------------------------------------------------------
# Resolve the working location, then extract workspace/<name> from it.
#
# Priority:
#   1. payload cwd (.cwd or .tool_input.cwd)
#   2. explicit -C <path> in the command
#   3. a `cd <path>` prefix in the command
#   4. any bare workspace/<name> path token in the command
# ------------------------------------------------------------------------------
CWD=$(echo "$INPUT" | jq -r '.cwd // .tool_input.cwd // empty' 2>/dev/null)

# Helper: pull the segment after the LAST `workspace/` in a string.
extract_project() {
  echo "$1" | grep -oE 'workspace/[A-Za-z0-9._-]+' | tail -1 | sed 's|workspace/||'
}

PROJECT=""

# 1. cwd-based (common case: `git pull` run from inside the clone).
if [ -n "$CWD" ]; then
  PROJECT=$(extract_project "$CWD")
fi

# 2. explicit -C <path> in the command.
if [ -z "$PROJECT" ]; then
  CDASH=$(echo "$COMMAND" | grep -oE '\-C[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/^-C[[:space:]]+//')
  if [ -n "$CDASH" ]; then
    PROJECT=$(extract_project "$CDASH")
  fi
fi

# 3. `cd <path> && git ...` prefix.
if [ -z "$PROJECT" ]; then
  CDPREFIX=$(echo "$COMMAND" | grep -oE 'cd[[:space:]]+[^[:space:]&|;]+' | head -1 | sed -E 's/^cd[[:space:]]+//')
  if [ -n "$CDPREFIX" ]; then
    PROJECT=$(extract_project "$CDPREFIX")
  fi
fi

# 4. any bare workspace/<name> token anywhere in the command.
if [ -z "$PROJECT" ]; then
  PROJECT=$(extract_project "$COMMAND")
fi

# Strip stray quotes the greps may have captured.
PROJECT=$(echo "$PROJECT" | sed "s/[\"']//g")

# Not a workspace clone op — nothing to suggest. This is the dominant no-op:
# ordinary `git pull` in the ops fork or any non-workspace repo lands here.
if [ -z "$PROJECT" ]; then
  exit 0
fi

cat >&2 <<MSG
> workspace/$PROJECT/ was updated via git (HEAD moved). Its search index may
  now be stale. Reindex THAT project so search_code / search_docs stay fresh:
    mcp__apexyard-search__reindex(scope="project", project="$PROJECT")
  Scoped to the changed project only — do not reindex the whole portfolio.
  If the MCP search server is unavailable, print a one-line warning and
  continue (best-effort signal).
MSG

exit 0

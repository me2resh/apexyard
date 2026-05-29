#!/bin/bash
# PostToolUse hook: prompts an MCP reindex after the /handover skill clones
# a repo into workspace/<name>/ at step 1.5-clone.
#
# Why this exists
# ---------------
# /handover SKILL.md step 1.5-clone clones the target repo immediately when a
# URL is given (default behaviour since #417). Step 1.5-reindex tells the agent
# to call mcp__apexyard-search__reindex(scope="project", project="<name>")
# right after the clone so the deep-dive phases that follow (steps 2–6) can use
# search_code / search_docs instead of falling back to grep + Read.
#
# In practice the reindex step is easily missed — it sits between two
# numbered steps in a long SKILL file. This hook fires on the matching
# git clone command and emits a one-line reminder banner, removing the
# "I forgot the rule applied here" failure mode.
#
# Behaviour
# ---------
#   - Fires on PostToolUse Bash where the command contains `git clone … workspace/…`
#     OR `git clone … <portfolio_workspace_dir>/…` (the helper-resolved form).
#   - Emits a single advisory banner to stderr naming the reindex command and
#     pointing at SKILL.md § 1.5-reindex.
#   - Exits 0 always — advisory, non-blocking. Same shape as
#     detect-role-trigger.sh / check-upstream-drift.sh.
#   - Silent no-op when:
#       * The command isn't a workspace clone
#       * The command failed (we don't want to suggest reindex on a failed clone)
#       * The repo doesn't ship an MCP search server (no mcp/ dir, no
#         apexyard-search package installed) — best-effort signal, not enforced
#
# Banner budget: ≤ 600 chars (this hook emits ~280 chars when it fires).
#
# Tests at .claude/hooks/tests/test_suggest_mcp_reindex_after_clone.sh.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Bail unless this is a git clone targeting a workspace dir. We match both the
# literal `workspace/` form (single-fork default) and any path ending in
# `/workspace/<name>` (the helper-resolved form used in split-portfolio v2).
#
# Patterns recognised:
#   git clone <url> workspace/<name>
#   git clone <url> "workspace/<name>"
#   git clone <url> /path/to/portfolio/workspace/<name>
#   git clone <url> "$WORKSPACE_DIR/<name>"   ← matched literally; the shell
#                                                 substitutes before run, so by
#                                                 the time PostToolUse fires the
#                                                 expanded path is in $COMMAND
if ! echo "$COMMAND" | grep -qE '\bgit\s+clone\b.*[/"'"'"']?workspace/[^[:space:]"'"'"']+[/"'"'"']?[[:space:]]*($|2>|1>|\|)'; then
  # Try the absolute-path workspace form
  if ! echo "$COMMAND" | grep -qE '\bgit\s+clone\b.*/workspace/[A-Za-z0-9._-]+'; then
    exit 0
  fi
fi

# Skip if the prior tool call failed — no point suggesting reindex on a clone
# that errored. PostToolUse input carries tool_response.exit_code on Bash.
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_response.exit_code // 0' 2>/dev/null)
if [ "${EXIT_CODE:-0}" != "0" ]; then
  exit 0
fi

# Extract the project name from the clone target — last path segment.
PROJECT=$(echo "$COMMAND" | grep -oE 'workspace/[A-Za-z0-9._-]+' | head -1 | sed 's|workspace/||' | sed 's/["'"'"']//g')

if [ -z "$PROJECT" ]; then
  # Couldn't parse the project name — still emit the banner without it.
  PROJECT="<name>"
fi

cat >&2 <<MSG
> Repo cloned into workspace/$PROJECT/. Next step (SKILL.md § 1.5-reindex):
    mcp__apexyard-search__reindex(scope="project", project="$PROJECT")
  Then use search_code / search_docs for the deep-dive (steps 2-6) instead of
  grep + Read. If the MCP server is unavailable, print one-line warning + set
  REINDEX_STATUS=unavailable and continue.
MSG

exit 0

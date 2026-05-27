#!/bin/bash
# Advisory hook: reminds the agent to try MCP search tools (search_docs,
# search_code) before falling back to grep+Read for codebase exploration.
#
# Fires on PreToolUse for Bash when the command matches grep/find patterns
# that target framework or project paths. Non-blocking (exit 0 always).
#
# The MCP vector search returns targeted excerpts from indexed chunks,
# saving ~3-5x tokens compared to reading full files via grep+Read.
#
# Wired to: PreToolUse → Bash (no `if` matcher — checks command internally)
# See: me2resh/apexyard#418

set -u

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# --- Detect grep/find patterns that MCP could serve better ----------------

is_search_command=false

case "$COMMAND" in
  grep\ -rn*|grep\ -r*|grep\ --include*|grep\ -l*)
    is_search_command=true ;;
  *"| grep"*)
    is_search_command=true ;;
esac

if echo "$COMMAND" | grep -qE '^find .+ -name .+\.(md|yaml|yml|ts|tsx|js|py)'; then
  is_search_command=true
fi

$is_search_command || exit 0

# --- Check if the search targets framework or project paths ---------------

targets_framework=false

framework_patterns=(
  ".claude/"
  "roles/"
  "workflows/"
  "templates/"
  "docs/agdr"
  "handbooks/"
  "skills/"
  "hooks/"
  "topologies/"
  "golden-paths/"
)

for pattern in "${framework_patterns[@]}"; do
  if echo "$COMMAND" | grep -q "$pattern"; then
    targets_framework=true
    break
  fi
done

# Also check for workspace/ or projects/ (managed project code)
if echo "$COMMAND" | grep -qE '(workspace/|projects/)'; then
  targets_framework=true
fi

$targets_framework || exit 0

# --- Emit advisory banner ------------------------------------------------

cat >&2 <<'BANNER'

💡 MCP search available — consider using it before grep+Read:

  • search_docs  — framework docs (skills, roles, handbooks, AgDRs, workflows)
  • search_code  — managed project codebases (workspace clones)

MCP returns targeted excerpts and saves ~3-5x tokens vs reading full files.
Load with: ToolSearch("select:mcp__apexyard-search__search_docs,mcp__apexyard-search__search_code")

BANNER

exit 0

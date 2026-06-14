#!/bin/bash
# SessionStart hook: reminds the agent to load MCP search tools at the
# start of every session. The tools are deferred (require ToolSearch to
# load schemas), which creates friction that causes agents to default to
# grep+Read instead.
#
# This banner is the cheapest possible fix for the deferred-tool friction
# problem — it puts the load command in the agent's context at session
# start so it doesn't have to remember to do it.
#
# Silent when: no MCP config exists (no .mcp.json at ops root or portfolio
# root — the MCP tools aren't set up, so reminding is pointless).
#
# See: me2resh/apexyard#418

set -u

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || exit 0

# Check if MCP is configured — look for .mcp.json in the repo root or
# the ops root (portfolio walkers may land us in a different root)
mcp_configured=false
r="$REPO_ROOT"
while [ -n "$r" ] && [ "$r" != "/" ]; do
  if [ -f "$r/.mcp.json" ]; then
    mcp_configured=true
    break
  fi
  r=$(dirname "$r")
done

$mcp_configured || exit 0

cat >&2 <<'BANNER'

📎 MCP search tools available (apexyard-search). Load before your first lookup:
   ToolSearch("select:mcp__apexyard-search__search_docs,mcp__apexyard-search__search_code,mcp__apexyard-search__reindex")

   Use search_docs for framework questions, search_code for project code.
   Fall back to grep+Read only when MCP results don't answer the question.

BANNER

exit 0

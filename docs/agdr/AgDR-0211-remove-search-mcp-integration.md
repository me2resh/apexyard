---
id: AgDR-0211
timestamp: 2026-10-03T09:00:00Z
agent: claude-code
model: claude-opus-5-5
session: apexyard2
trigger: user-prompt
status: executed
category: integrations
---

# Remove the search MCP integration from the framework

> I removed every framework reference to the optional search MCP server. Hooks and agents advised a server that was not running. `grep` and `Read` are now the one search path. Forks that run the server wire it themselves.

## Context

The framework named the `apexyard-search` MCP server in six hooks and twelve agent tool lists. Two rules, `/handover`, the Codex sync script and two adapters also named it. The server is not in this repository. AgDR-0186 made the integration optional.

`suggest-mcp-search.sh` checked only that `.mcp.json` named the server. When the binary was missing, the session reported a failed MCP connection. The hook still told the agent that the MCP was available.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the integration and add a liveness check | Configured forks keep the nudges | The framework keeps code for a component it does not ship |
| Remove the integration | One search path: `grep` and `Read`. No advice about tools that do not exist | Forks that run the server lose the nudges and agent tool entries |

## Decision

Remove the integration. Agents, rules and skills use `grep` and `Read`. The adapters keep their generic unsupported-wire check for `Read|Glob|Grep` hooks. A fork can still configure any MCP server in its own `.mcp.json`.

## Consequences

- Six hooks, their tests, and the `mcp_search` config keys are gone.
- Rex and Tariq discover handbooks by path convention only.
- This decision supersedes AgDR-0056, AgDR-0058, AgDR-0070 and AgDR-0186.

## Artifacts

- me2resh/apexyard#1537

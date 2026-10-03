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

> In the context of an optional search MCP server that is not part of this repository, facing hooks and agent text that advised a server that was not running, I decided to remove every framework reference to the server to achieve one documented search path, accepting that forks which run the server must wire it themselves.

## Context

The framework named the `apexyard-search` MCP server in six hooks, twelve agent tool lists, two rules, `/handover`, the Codex sync script, and the pi and opencode adapters. The server is not in this repository. AgDR-0186 made the integration optional.

`suggest-mcp-search.sh` checked only that `.mcp.json` named the server. When the binary was missing, the session reported a failed MCP connection, and the hook still told the agent on each search-shaped Bash call that the MCP was available.

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

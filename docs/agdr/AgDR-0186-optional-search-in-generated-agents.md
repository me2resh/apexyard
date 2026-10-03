# AgDR-0186: Keep optional search out of unconfigured adapters

**Status:** Superseded by [AgDR-0211](AgDR-0211-remove-search-mcp-integration.md). The framework no longer ships the search MCP integration.

> In generated Codex guidance, I use the fork's search MCP configuration as a generation hint. Runtime tool availability remains the final check.

## Context

Claude agents list optional search tools in their frontmatter. Codex generation omits that frontmatter but copies exact Claude tool names into agent and skill instructions. An unconfigured fork can therefore show tool names that its agents cannot call.

The agent must still complete code and handbook reads without semantic search. The tool list determines whether a running agent can call search.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Keep exact names in every generated file | Generation stays identical across forks | Unconfigured forks show unavailable tool names |
| Remove exact names when the fork has no search MCP entry | Generated guidance matches the fork's declared capability | Regeneration is needed after configuration changes |

## Decision

Use the fork's `.mcp.json` entry for `apexyard-search` as the generation hint. Remove exact MCP tool identifiers from generated Codex guidance when the entry is absent. Keep the fallback instructions. Keep runtime tool-list checks in the source agents and skills.

This check does not prove that a configured server is running. Agents still use `grep` and `Read` when a tool is absent or fails.

## Consequences

- Unconfigured forks receive usable instructions without unavailable MCP tool identifiers.
- Configured forks retain the exact names after adapter regeneration.
- A user-level MCP installation without a fork entry gets the conservative generated guidance.

## Artifacts

- `bin/sync-codex-adapter.sh`
- `.claude/hooks/tests/test_search_mcp_optional.sh`

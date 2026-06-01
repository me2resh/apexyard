# Make sub-agents MCP-first (prompt-level, mirroring the main-loop rule)

> In the context of the "use MCP search before grep" rule only reaching the main agent loop, facing a confirmed case where the `tech-lead` sub-agent read a managed-project codebase entirely via `grep`/`Read` (zero `search_code` calls in `activity.jsonl`), I decided to make the code-reading sub-agents MCP-first at the prompt + tools level — add `mcp__apexyard-search__search_code` + `search_docs` to their `tools`/`allowed-tools` and a short "MCP-first" instruction block to each agent body — rather than try to extend the `suggest-mcp-search.sh` hook into sub-agent contexts, to achieve consistent MCP-first behaviour across delegated work, accepting that this is self-discipline (prompt-level) rather than mechanical enforcement.

## Context

The portfolio rule "prefer `mcp__apexyard-search__search_code` / `search_docs` over `grep` + `Read`" is enforced on the **main loop** two ways: the `suggest-mcp-search.sh` PreToolUse advisory hook (fires on the main agent's Bash/grep calls and injects a `hookSpecificOutput.additionalContext` nudge), and operator feedback memory. Neither reaches a spawned sub-agent: the hook observes the *main* agent's tool calls, and a sub-agent runs its own loop with its own (separately-declared) tools.

Observed 2026-06-01 (this is the originating incident): the `tech-lead` sub-agent authored a curios-dog Cognito migration design by reading the Terraform + DynamoDB code via `grep`/`Read`. The MCP `activity.jsonl` showed **zero** `search_code` entries for that run. The design came out correct, but via the more expensive path the rule exists to avoid. Filed as me2resh/apexyard#475.

Two contributing facts:

1. The engineering/data agent definitions carried `search_docs` at most (most carried neither `search_code` nor `search_docs` in their `tools`/`allowed-tools` line), so the tool wasn't even available to them.
2. Their agent prompts had no MCP-first instruction.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Extend `suggest-mcp-search.sh` to fire inside sub-agent contexts** | Mechanical (not self-discipline) | The hook observes the *invoking* loop's tool calls; sub-agent tool calls aren't surfaced to the parent hook in a way the current PreToolUse plumbing can intercept. Would need harness-level changes we don't control. High effort, uncertain feasibility. |
| **Prompt-level MCP-first in each agent + add the tools (chosen)** | Simple, additive, immediately effective; reuses the proven `solution-architect` agent shape (which already does this); no harness changes | Self-discipline, not mechanically enforced — a sub-agent *could* still grep. Matches how the main-loop rule degrades, so no worse than today's primary mechanism. |
| **Do nothing (rely on the per-call prompt to say "prefer search_code")** | Zero change | The originating incident shows an ad-hoc per-spawn instruction isn't reliable; the discipline belongs in the agent definition, not in each caller's prompt. |

## Decision

Chosen: **prompt-level MCP-first, baked into the agent definitions.**

1. **Add the MCP search tools** (`mcp__apexyard-search__search_code` + `search_docs`) to the `tools` / `allowed-tools` line of every code-reading sub-agent: `tech-lead`, `backend-engineer`, `frontend-engineer`, `data-engineer`, `platform-engineer`, `qa-engineer`, `security-reviewer`. (The `code-reviewer` already had `search_docs`; the new `solution-architect` already has both + the instruction — it's the reference implementation.)
2. **Add a short `## MCP-first code search` block** to each agent body: prefer `search_code`/`search_docs` over `grep`+`Read`; fall back to grep only when MCP returns nothing (e.g. project not indexed). One consistent paragraph across all seven.
3. **Do NOT attempt to extend the hook** into sub-agent contexts for now — the hook plumbing can't see a sub-agent's tool calls, and the prompt-level lever matches how the main-loop rule already works (advisory + self-discipline). Recorded here so a future maintainer doesn't re-investigate the hook route assuming it's a quick win.

## Consequences

- The seven code-reading agents now have `search_code`/`search_docs` available and an explicit MCP-first instruction. A spawned agent reviewing/authoring against a managed project should now produce `search_code` entries in `activity.jsonl` (verifiable).
- Fallback to grep when MCP returns nothing is preserved — no hard dependency on MCP (adopters without it see unchanged behaviour).
- This is self-discipline, not a gate. If a future need for *mechanical* enforcement arises, it requires harness-level work (sub-agent tool-call interception) that's out of scope here.
- No framework-count change (agent count unchanged — these are edits to existing agents), so `test_site_counts.sh` is unaffected.

## Artifacts

- Issue: me2resh/apexyard#475
- Edited: `.claude/agents/{tech-lead,backend-engineer,frontend-engineer,data-engineer,platform-engineer,qa-engineer,security-reviewer}.md` (tools line + MCP-first block)
- Reference implementation: `.claude/agents/solution-architect.md` (#472 — already MCP-first)
- Related: `suggest-mcp-search.sh` (#418, #469/#470 — the main-loop hook), the "use MCP before grep" operator feedback rule, AgDR-0050 (agent runtime / tools conventions).

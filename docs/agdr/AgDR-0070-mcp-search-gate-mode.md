# Optional mechanical gate mode for suggest-mcp-search.sh

> In the context of `suggest-mcp-search.sh` being advisory-only (exit 0), facing agents that routinely ignore the nudge and fall straight to `grep -r`/`find` over indexed paths (burning ~3–5× tokens), I decided to add an **opt-in, config-gated soft-block (exit 2) with a per-call escape hatch** to the existing hook, to achieve mechanical enforcement of the MCP-first path for operators who want it, accepting that the gate is strictly opt-in and only covers the Bash exploratory-search branch (never read→edit).

## Context

`suggest-mcp-search.sh` emits an `additionalContext` advisory (exit 0) when an agent runs exploratory `grep -r`/`find` over indexed framework/project paths and `apexyard-search` is configured. It is purely advisory — the agent can ignore it, and routinely does. Operators who rely on the MCP index have no way to *enforce* the token-saving path. Issue #651 asks for an optional mechanical gate.

Constraints that shape the design:

- A hook **cannot call MCP or reindex** — it can only block and instruct. So the gate can't verify "MCP already returned nothing"; the agent must be able to assert that and proceed.
- The **read→edit flow needs real line numbers** — `Read`/`Glob`/`Grep` before an `Edit` must never be blocked.
- The feature must be **invisible to free adopters** and those without the search component — same install-gate as the advisory.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Stay advisory-only (status quo) | Zero risk; never blocks legitimate work | The exact problem #651 reports — agents ignore it, no enforcement path |
| **Opt-in config-gated soft-block (exit 2) on the Bash branch, with a per-call escape hatch** | Mechanical enforcement for operators who want it; default-off so nobody is surprised; read→edit untouched; escape hatch handles the empty-index / non-indexable / stale case | A new config key + env-var contract to document; agent must learn the escape hatch |
| Hard-block (exit 2, no escape) | Strongest enforcement | Breaks the legitimate empty-result and non-indexable-repo cases — the hook can't know MCP already failed, so this would deadlock the agent |
| Block Read/Glob/Grep too | Closes the native-tool bypass under the gate | Breaks read→edit (you need line numbers before an Edit); explicitly out of scope per #651 |

## Decision

Chosen: **opt-in config-gated soft-block on the Bash exploratory-search branch, with a per-call escape hatch**, because it gives enforcement to operators who opt in without changing anything for everyone else, and the escape hatch preserves every legitimate case the hook can't detect.

Specifics:

- New config key `mcp_search.gate_mode` (boolean, **default `false`**) in `.claude/project-config.defaults.json`. Gate mode activates only when this is `true` **and** `apexyard-search` is configured (the existing install-gate).
- The gate applies **only to the Bash `grep -r`/`find`-over-indexed-paths branch**. `Read`/`Glob`/`Grep` stay advisory-only (exit 0) so read→edit is never blocked.
- **Per-call escape hatch** `APEXYARD_MCP_FALLBACK=1`: recognised both as a real environment variable (operator/session level) and as a token in the command string (`APEXYARD_MCP_FALLBACK=1 grep -r …` — the per-call form the agent uses on a retry). When present, the gate steps aside (falls through to the advisory).
- On block: **exit 2** with a stderr message (PreToolUse non-zero stderr is surfaced to the agent) explaining why, instructing `search_code`/`search_docs` first, and naming the escape hatch for the empty-index / non-indexable / stale-index case.
- **Stale-index detection** (the "optionally" in #651) is folded into the escape-hatch message rather than implemented as HEAD-comparison: the hook has no reliable signal for the MCP index's freshness, so it instructs the agent to retry with the escape hatch if MCP already came back empty/stale, rather than asserting false precision.

## Consequences

- Operators who set `mcp_search.gate_mode: true` get mechanical MCP-first enforcement on exploratory shell search; everyone else is unaffected (default-off + install-gated).
- The agent must use `search_code`/`search_docs` first under the gate, and append `APEXYARD_MCP_FALLBACK=1` to a retried command when MCP genuinely can't serve it.
- The advisory path (gate off) is byte-for-byte unchanged, so existing behaviour and tests hold.
- A future enhancement could add real stale-index detection if the search component exposes an index-timestamp signal a hook can read.

## Artifacts

- Issue: me2resh/apexyard#651
- Hook: `.claude/hooks/suggest-mcp-search.sh`
- Config: `.claude/project-config.defaults.json` → `mcp_search.gate_mode`
- Tests: `.claude/hooks/tests/test_suggest_mcp_search.sh`
- Related: #418 (original), #469 (additionalContext + install-gate), #489 (Read/Glob/Grep extension)

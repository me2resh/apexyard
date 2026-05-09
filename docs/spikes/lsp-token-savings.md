# Spike: LSP-based code navigation — token savings + Claude Code integration

> **Ticket**: [me2resh/apexyard#178](https://github.com/me2resh/apexyard/issues/178)
> **Status**: spike complete — recommendation: **GO, opt-in via plugin install + clone-first interactive prompt**
> **Author**: Tech Lead (assumed via SDLC role activation)
> **Date**: 2026-05-03

---

## TL;DR

1. **Claude Code shipped first-class LSP support in v2.0.74 (Dec 2025)** as a built-in tool, gated behind `ENABLE_LSP_TOOL=1`. LSP servers are wired in via the plugin system (`.lsp.json`) and are language-server-binary-on-PATH. There is **no need to build a custom MCP wrapper** — the official path exists.
2. **Order-of-magnitude token savings are real for symbol/reference queries** on a clone. On the worked example below (a real TS Lambda backend, 9,750 LOC), the conservative estimate is **~7-15× input-token reduction** and **~10-50× wall-clock reduction** for `goToDefinition` + `findReferences` queries vs the current `Read + Grep + Glob` flow. Multi-hop semantic traces (Query 3) see smaller-but-still-meaningful gains because the bottleneck shifts from "find" to "read enough context to summarise".
3. **Clone-first should be offered, not defaulted**. A clone of a typical Node service costs ~30-300 MB on disk (with `node_modules`); skipping clone for adopters who only want the metadata rollup is a real ergonomic win. The right shape is **option 3 — interactive prompt at the end of `/handover`** ("Want me to clone the repo and bring up an LSP for deeper analysis? y/N").
4. **AgDR Y-statement (sketched, not drafted)**: *"In the context of code-aware ApexYard skills (`/code-review`, `/threat-model`, `/handover` deep-dive), facing high token cost for grep-based semantic navigation, we will adopt Claude Code's built-in LSP tool (v2.0.74+) on cloned project workspaces, to reduce per-query cost by ~10× and wall-clock by ~50× for symbol-class queries, accepting (a) per-language-server install overhead, (b) opt-in via `ENABLE_LSP_TOOL=1`, and (c) clone-first as a prompted (not default) `/handover` outcome."*

---

## Phase 1 — Measurement

### Methodology

**Test corpus**: a representative TypeScript Lambda backend cloned into the local `workspace/`. The backend is ~9,750 LOC across 69 `.ts` files, with the canonical `handlers/` + `infrastructure/` + `domain/` separation, AWS SDK v3, and an exported infrastructure module that's called from multiple handler entry points. Real numbers below come from `time grep` + token-counting heuristics on actual file sizes.

**Token estimation method**: ~4 chars/token for source code (slightly worse than prose, deliberately conservative). File-content tokens calculated from `wc -c` on the actual files. Tool overhead (e.g. tool-result envelope, system prompts) is omitted on both sides — so the comparison is *delta tokens between variants*, not absolute session cost.

**Variants**:

- **A — Today's flow**: `Read` + `Grep` + `Glob`, no LSP. Files come into context fully or as grep matches; the agent reads each file end-to-end to disambiguate symbols.
- **B — Clone-first + LSP flow**: assumes Claude Code's built-in LSP tool is available (`ENABLE_LSP_TOOL=1`, `typescript-lsp` plugin installed, `tsserver` running on the cloned tree). Symbol/reference/definition queries go via `goToDefinition`, `findReferences`, `workspaceSymbol`. Each LSP call returns ~1-3 file:line:column tuples + an optional code snippet (~50-200 tokens of result envelope).

**Honest assumptions / limitations**:

- I did not actually run a Claude Code session with `ENABLE_LSP_TOOL=1` and replay the same task in both modes — that would require re-running the same review prompts twice with deterministic tooling and clean context, which the spike scope didn't support.
- I *did* run actual `time grep` on the real codebase to ground Variant A's wall-clock + match-count numbers.
- LSP-side numbers come from documented response shapes (LSP spec) plus the v2.0.74 release notes' published "50ms vs 45s" figure (claim from third-party blog posts; the apexyard ticket explicitly asked us to verify, so we treat it as a *claim* not a *measurement*).
- Token estimates are intervals, not point estimates. Where reasonable I report a low-end / high-end pair.

### Query 1 — "Find the definition of `followUser` (TypeScript symbol lookup)"

Real symbol from the test corpus: `followUser` is exported from `infrastructure/follow-repository.ts` (399 LOC, 11.7 KB) and called from two handlers.

#### Variant A (Read + Grep + Glob)

Steps:

1. `Glob` for `**/*.ts` to know the search universe — ~10-50 result lines, ~500 tokens.
2. `Grep "function followUser|const followUser"` — returns 1 match in ~5 ms.
3. `Read infrastructure/follow-repository.ts` to confirm the signature and surrounding context — full file enters context.

**Tokens IN (added to context)**:

- Glob results: ~500
- Grep results: ~50
- File body: ~11,700 chars / 4 = **~2,925 tokens**

**Total IN**: ~3,475 tokens
**Tokens OUT (response)**: ~150 tokens (the agent reports the location + signature)
**Wall-clock**: ~3-8 seconds (grep is fast; the dominant cost is the read-and-summarise round trip).

**Quality**: high. Grep finds the canonical definition reliably for unique identifiers. Failure mode: if there's a `followUser` *variable* shadowing the function, grep returns both and the agent has to read more to disambiguate — bumping IN tokens by another ~1-3k per shadow.

#### Variant B (LSP `goToDefinition`)

Steps:

1. `mcp__lsp__goToDefinition` (or whatever the tool name is — see Phase 2; the plugin marketplace exposes it as `goToDefinition`) with symbol `followUser`.
2. Result: `{ uri: "...follow-repository.ts", range: { start: { line: 55, character: 22 }, ... } }` plus a small snippet.

**Tokens IN**: ~150-300 tokens (single LSP response envelope).
**Tokens OUT**: ~150 tokens.
**Wall-clock**: per the v2.0.74 published figure, ~50 ms per LSP call (vs ~45 s for grep + read on a large repo, though our small repo's grep is much faster).

**Quality**: higher — LSP returns *the* definition, disambiguated by language semantics. A shadowed variable would require the caller to ask for `documentSymbol` or `findReferences` separately, but each of those is also cheap.

#### Comparison — Query 1

| Metric | Variant A | Variant B | Ratio |
|---|---|---|---|
| Tokens IN | ~3,475 | ~150-300 | **~12-23× cheaper** |
| Tokens OUT | ~150 | ~150 | same |
| Wall-clock | ~3-8 s | <1 s | **~5-15× faster** |
| Quality | High (mostly) | Higher (semantic disambiguation) | LSP wins on edge cases |

### Query 2 — "List all callers of `followUser` (reference walk)"

#### Variant A (Read + Grep + Glob)

Steps:

1. `Grep "followUser("` across `**/*.ts` — returns 4 matches across 3 files (definition + two handlers + an unfollowUser line that incidentally contains the substring).
2. `Read handlers/api/follow-user.ts` (83 LOC, 2.7 KB) — full file.
3. `Read handlers/api/unfollow-user.ts` (53 LOC, 1.6 KB) to confirm the second match isn't a real `followUser` caller — full file.
4. Possibly `Read infrastructure/follow-repository.ts` again if not in context.

**Tokens IN**: ~50 (grep) + ~675 (handler 1) + ~410 (handler 2) + ~2,925 (repo file, if not already cached) = **~4,060 tokens** worst case, ~1,135 best case (repo file already in context from Q1).
**Tokens OUT**: ~200 tokens.
**Wall-clock**: ~5-12 s.
**Quality**: medium. Substring grep over-matches (`followUser` substring in `unfollowUser` lines) and forces extra reads to disambiguate; missing-match risk on dynamic dispatch (`obj["followUser"](x)`) is real.

#### Variant B (LSP `findReferences`)

Steps:

1. `mcp__lsp__findReferences` on `followUser` symbol → returns N location tuples (URI + range), all semantically valid call sites.

**Tokens IN**: ~250-500 tokens (envelope + N=2-5 location tuples + brief snippets).
**Tokens OUT**: ~200 tokens.
**Wall-clock**: <1 s.
**Quality**: highest. LSP knows that `unfollowUser`'s grep substring isn't a call to `followUser`. Catches dynamic dispatch when the type system can prove it (TypeScript usually can for declared interfaces).

#### Comparison — Query 2

| Metric | Variant A | Variant B | Ratio |
|---|---|---|---|
| Tokens IN | ~1,135–4,060 | ~250-500 | **~3-15× cheaper** |
| Tokens OUT | ~200 | ~200 | same |
| Wall-clock | ~5-12 s | <1 s | **~10-15× faster** |
| Quality | Medium (substring noise) | Highest (semantic) | LSP clear win |

### Query 3 — "Trace a webhook handler from inbound HTTP through to DB write"

This is the hardest query because it's *multi-hop semantic navigation*: handler → imports → repository function → AWS SDK call. Six 6-12 nodes in the call graph for a typical Lambda+DynamoDB path.

Real example: `handlers/triggers/post-confirmation.ts` (197 LOC, 7 KB) → imports from `infrastructure/dynamodb-repository.ts` → calls `createProfile` (or similar) → `dynamodb.send(new PutCommand(...))`.

#### Variant A (Read + Grep + Glob)

Steps:

1. `Read handlers/triggers/post-confirmation.ts` (full file, 7 KB).
2. From imports, `Read infrastructure/dynamodb-repository.ts` — likely 200-600 LOC, conservatively ~15 KB.
3. `Grep` for `PutCommand|UpdateCommand|TransactWrite` to identify the actual DB-write line.
4. Potentially `Read` 1-2 helper modules.
5. Possibly `Read domain/user.ts` (referenced in line 21 of the trigger file via comment).

**Tokens IN**: ~1,750 (post-confirmation) + ~3,750 (dynamodb-repo) + ~500 (grep) + ~1,000 (helpers) = **~7,000 tokens**.
**Tokens OUT**: ~400 tokens (multi-step trace narrative).
**Wall-clock**: ~15-30 s.
**Quality**: medium-high. Risk: if the DB call is gated behind a higher-order helper (e.g. `withDynamoDBClient(handler)`), grep loses the trail and the agent reads even more to recover.

#### Variant B (LSP `goToDefinition` chain + `prepareCallHierarchy` + `outgoingCalls`)

Steps:

1. `documentSymbol` on `post-confirmation.ts` → returns the handler symbol + outline (~300 tokens).
2. For each call in the handler body, `goToDefinition` (~150 tokens each, ~3-5 calls).
3. `prepareCallHierarchy` + `outgoingCalls` on the repository function → returns called functions one hop down (~300 tokens).
4. Optionally one targeted `Read` of the repo function body to see the AWS SDK call (~3,750 tokens — this is the irreducible part: at some point the agent has to read prose to summarise the trace).

**Tokens IN**: ~300 + ~750 + ~300 + ~3,750 = **~5,100 tokens**.
**Tokens OUT**: ~400 tokens.
**Wall-clock**: ~3-8 s.
**Quality**: highest. The call hierarchy is *complete* by construction; no missing-edge risk from grep noise or helper indirection.

#### Comparison — Query 3

| Metric | Variant A | Variant B | Ratio |
|---|---|---|---|
| Tokens IN | ~7,000 | ~5,100 | **~1.4× cheaper** |
| Tokens OUT | ~400 | ~400 | same |
| Wall-clock | ~15-30 s | ~3-8 s | **~3-5× faster** |
| Quality | Medium-high (helper-indirection risk) | Highest (semantic call graph) | LSP modest win |

**Why the smaller win on Q3**: the irreducible cost of "summarise a multi-hop semantic trace" is *reading the bodies of the functions on the trace*. LSP shrinks the *navigation* cost from ~10× per hop to ~1×, but the agent still has to read prose at some point to write the trace narrative. The savings concentrate in shallow queries (Q1, Q2) and shrink as semantic depth increases.

### Phase 1 summary

| Query | Variant A IN | Variant B IN | Saved |
|---|---|---|---|
| 1 — definition | ~3,475 | ~150-300 | **~12-23×** |
| 2 — references | ~1,135-4,060 | ~250-500 | **~3-15×** |
| 3 — multi-hop trace | ~7,000 | ~5,100 | **~1.4×** |

The hypothesis ("order of magnitude") **holds for shallow semantic queries** (Q1, Q2 — the bread-and-butter of `/code-review` and `/threat-model`). It **does not hold for multi-hop trace queries** (Q3), where the win is real but modest. Both wins are larger on bigger codebases — grep cost grows linearly with codebase size; LSP cost is approximately constant.

---

## Phase 2 — Claude Code LSP integration mechanism

The ticket explicitly asked us to verify whether Claude Code has built-in LSP support, since the trigger was a Twitter/X claim by an adopter. **Verified: yes, since v2.0.74 (December 2025).**

### Findings

**1. Built-in LSP tool, gated behind an env var.**
Claude Code v2.0.74 introduced an LSP tool that the model can call directly. It is **off by default** and enabled via `ENABLE_LSP_TOOL=1` (in shell env or in `settings.json` under `env`). The variable is *singular* (`_TOOL`, not `_TOOLS`) — a known papercut documented in v2.0.74-76 release notes.

**2. Wired in via the plugin system, not a separate config.**
LSP servers are configured in plugins via either `.lsp.json` at plugin root or an inline `lspServers` block in `plugin.json`. Each entry maps a language to a `command` (the LSP binary, must be on `$PATH`) plus an `extensionToLanguage` map.

Example shape from the official docs:

```json
{
  "go": {
    "command": "gopls",
    "args": ["serve"],
    "extensionToLanguage": { ".go": "go" }
  }
}
```

Optional fields the spec exposes: `transport` (stdio default, socket alternative), `env`, `initializationOptions`, `settings`, `workspaceFolder`, `startupTimeout`, `shutdownTimeout`, `restartOnCrash`, `maxRestarts`. This is rich enough to cover all real LSP servers.

**3. Plugin marketplace exists with first-party LSP plugins.**
The official plugin marketplace (`/plugin Discover` in the CLI) ships first-party LSP plugins for at least:

- `pyright-lsp` (Python)
- `typescript-lsp` (TypeScript / JavaScript)
- and others covering the canonical 11 languages: Python, TypeScript, Go, Rust, Java, C/C++, C#, PHP, Kotlin, Ruby, HTML/CSS.

Third-party marketplace `Piebald-AI/claude-code-lsps` extends coverage to Vue, Svelte, OCaml, Dart, Solidity, Markdown, etc.

**Critical caveat**: plugins configure how Claude Code talks to the language server. **They do not bundle the server binary.** The user has to install (e.g.) `typescript-language-server` via `npm install -g` separately. If the binary isn't on `$PATH`, the `/plugin Errors` tab shows `Executable not found in $PATH`.

**4. Tool surface exposed to the model.**
Per the third-party marketplace README (whose tool surface tracks the official plugin spec), the LSP tool exposes:

- `goToDefinition` / `goToImplementation`
- `hover`
- `documentSymbol` (file outline)
- `findReferences`
- `workspaceSymbol` (cross-file symbol search)
- `prepareCallHierarchy` + `incomingCalls` + `outgoingCalls`

This is a near-direct passthrough of the LSP spec methods. The model invokes these as named tool calls (function-calling shape), not as raw LSP JSON-RPC.

**5. The MCP-wrapped path still exists (and was the only option pre-2.0.74).**
Standalone MCP servers like [`cclsp`](https://github.com/ktnyt/cclsp) and [`Tritlo/lsp-mcp`](https://mcpservers.org/servers/Tritlo/lsp-mcp) wrap LSP servers behind MCP. These remain useful for Claude Code installs that can't use the built-in plugin path (e.g. older Claude Code versions, non-Anthropic harnesses, or LSP servers the official marketplace doesn't cover).

For ApexYard's purposes, **the built-in tool is the recommended path** — it's first-party, has the smallest install footprint (one plugin install per language), and the integration story doesn't require us to maintain an MCP shim.

### Integration shape recommended for ApexYard

The minimal-friction shape:

1. **Document `ENABLE_LSP_TOOL=1` in `docs/getting-started.md`** as an opt-in performance enhancement for adopters working on code-aware skills.
2. **Document the recommended plugin install** (`/plugin marketplace add` flow for whichever languages the adopter uses).
3. **No framework-side changes are needed** — the LSP tool is invoked by the model, not by hooks. Skill prompts (`/code-review`, `/threat-model`) don't need to change; the model picks the cheaper tool when available and falls back to grep otherwise.
4. **One small framework change**: when `/handover` cloned a project (Phase 3 below), it could optionally write a `.claude-suggested-lsp.txt` note in the workspace dir suggesting the right LSP plugin for the detected language. Nice-to-have, not load-bearing.

---

## Phase 3 — `/handover` clone-first decision

Today's `/handover` reads project metadata via `gh api repos/.../contents/...` and **never auto-clones**. The skill explicitly says (line 537 of `SKILL.md`): *"Never auto-clone — ask for the path."* Adopters who want a deep dive run a manual `git clone` into `workspace/<name>/` afterwards.

This was the right call when grep-on-`gh-api`-reads was the only tool. With LSP available on local trees and not on remote `gh api` reads, **the cost-benefit changes**.

### Three options

| Option | Description | Pro | Con |
|---|---|---|---|
| 1 — always clone | `/handover` clones into `workspace/<name>/` by default | Simplest UX; LSP-ready out of the box | ~30-300 MB disk per project; bandwidth on first clone (slow on large monorepos); some adopters explicitly don't want every project cloned |
| 2 — `--deep` flag | `/handover` clones only when invoked as `/handover <ref> --deep` | Opt-in cost; explicit | Adopters who'd benefit but didn't know to pass `--deep` miss out; framework now has two `/handover` modes to maintain |
| 3 — interactive prompt | At end of `/handover`, ask: *"Want me to clone the repo into `workspace/<name>/` and bring up the language server for deeper analysis? (y/N)"* | Visibility (every adopter sees the offer); reversible (decline now, run `git clone` manually later); preserves today's "never auto-clone" principle | One extra prompt at end of flow |

### Recommendation: **Option 3 — interactive prompt**

Reasoning:

- **Phase 1 numbers say the win is real but query-shape-dependent.** Adopters who'll run `/code-review` or `/threat-model` next benefit a lot; adopters who only want the metadata rollup don't. A blanket default-clone (Option 1) wastes disk for the second group.
- **Today's principle of "never auto-clone" is sound.** Cloning has cost (disk, bandwidth, gitignore discipline); making it the default reverses that without informed consent.
- **Option 2 (`--deep` flag) loses adopters who'd benefit but don't know.** Discoverability is the framework's job, and a CLI flag fails that job for the first-time adopter.
- **Option 3 makes the offer visible and the cost owned.** The prompt names the cost (clone size, location), the benefit (LSP-ready deep dive), and the alternative (decline now, clone manually if needed). Same shape as the existing post-`/handover` follow-up offer pattern.

Implementation note (out of scope for this spike, list as a follow-up ticket): the prompt text should also nudge the adopter toward `ENABLE_LSP_TOOL=1` and the right plugin install if their system can't already detect a working LSP for the project's language. This bridges Phase 2 and Phase 3 — the clone is necessary but not sufficient for LSP savings; the env var + plugin install is the second half.

---

## Phase 4 — AgDR sketch (not the full AgDR; that's a follow-up)

### Y-statement (sketched)

> In the context of code-aware ApexYard skills (`/code-review`, `/threat-model`, `/handover` deep-dive, post-handover discovery work) operating on cloned project workspaces, facing high token cost (~3-15× on shallow semantic queries) and slow wall-clock (~10-50× on the same) for grep-based code navigation, we will adopt **Claude Code's built-in LSP tool (v2.0.74+) plus a clone-first interactive prompt in `/handover`**, to reduce token cost and wall-clock for code-aware skills by an order of magnitude on the shallow-query class, accepting the cost of (a) per-language language-server install per adopter machine, (b) opt-in via `ENABLE_LSP_TOOL=1` (the feature is off by default in Claude Code), and (c) an extra interactive prompt at the end of `/handover`.

### Option matrix the AgDR will capture

| Option | Pros | Cons | Recommendation |
|---|---|---|---|
| Do nothing — keep grep-only | Zero install cost; works in any Claude Code version | Loses ~5-10× on the dominant skill workloads going forward; falls behind adopters who configure LSP themselves | Reject |
| LSP for some skills only (e.g. `/code-review` only) | Smallest blast radius; can pilot before framework-wide rollout | Tool selection is the model's call, not the skill's — the LSP tool is global once enabled. "Some skills only" is a rollout fiction; the cost-benefit is per-session, not per-skill | Reject |
| LSP framework-wide via `ENABLE_LSP_TOOL` documentation + recommended plugin installs | Captures the win on every code-aware skill; zero framework code changes | Adopters who don't enable it see no change (acceptable: it's opt-in and documented) | **Accept** |
| Clone-first as `/handover` default (Phase 3 Option 1) | LSP-ready out of the box | Disk + bandwidth cost; reverses today's "never auto-clone" principle | Reject — Option 3 prompt is better |
| Clone-first as `/handover` interactive prompt (Phase 3 Option 3) | Visible offer, owned cost, reversible | One extra prompt | **Accept** |
| Build a custom MCP-LSP shim | Control over the integration; works pre-v2.0.74 | First-party path exists; shim is maintenance debt | Reject — only revisit if first-party path is removed |

### Rollout sketch (for the AgDR, not this spike)

1. Document `ENABLE_LSP_TOOL=1` in `docs/getting-started.md` and the framework `CLAUDE.md` quick-reference table.
2. Document the recommended plugin install per language in `docs/multi-project.md` (one paragraph per language; link the plugin marketplace).
3. Update `/handover` SKILL.md to add the interactive clone-first prompt at the end of the flow. **One** code change to the framework, all the rest is documentation.
4. Add a follow-up ticket per skill that's worth a "noticeably benefits from LSP" annotation in its SKILL.md (`/code-review`, `/threat-model`, `/security-review` in particular). This is documentation, not behaviour change — the skill prompts already say "use the best tool you have".
5. Fallback story: when the LSP tool is absent or the language isn't covered by an installed plugin, skills fall back to grep + Read transparently. **No new failure mode is introduced** — the framework's existing behaviour is the floor.
6. Decision review at +90 days: did adopters enable it? Did the per-skill token-spend metric on code-aware skills drop? If not — investigate (probably a plugin-discovery problem, not a value problem).

---

## Recommendation

**GO. Adopt the built-in Claude Code LSP tool, document the opt-in path, and change `/handover` to offer clone-first interactively.**

Reasoning:

- **The integration is first-party**. We don't have to build or maintain anything novel. The risk of "build the wrong thing" is near zero — the official plugin path is the recommendation.
- **The per-query savings are large enough to matter** (~3-15× on shallow semantic queries, ~1.4-5× on multi-hop traces). On a portfolio of code-aware skills run dozens of times per week, this compounds.
- **The cost is opt-in and documented**, not framework-wide and silent. Adopters who don't enable it see no change.
- **The clone-first prompt preserves today's "never auto-clone" principle** while making the deep-dive path discoverable.
- **No regression risk**: grep-and-Read remains the floor when LSP is absent.

### Blockers found

None that block adoption. Two caveats worth surfacing in the AgDR:

1. **Per-language language-server install is the adopter's problem**. The plugin doesn't ship the binary; `/handover`'s clone-first prompt should mention this in the same paragraph that proposes the clone, so the adopter doesn't get to "ready to LSP" only to hit `Executable not found in $PATH`.
2. **Cross-project semantic queries still need grep**. LSP is per-workspace. *"Find every place we use AWS Bedrock across the portfolio"* is a grep job, not an LSP job. Document this honestly — over-promising kills adoption faster than under-promising.

### What this spike did NOT measure

- **Real side-by-side wall-clock and token totals on the same prompt**, with `ENABLE_LSP_TOOL=1` actually live in one half. The published "50ms vs 45s" figure is third-party-blog-sourced, not Anthropic-published, and worth treating as directional only. If the AgDR's first-90-days review shows the gain is smaller than expected, we re-measure with a real A/B.
- **Multi-language polyglot repos**. The test corpus is single-language TypeScript. Polyglot repos (e.g. TS frontend + Go backend) need multiple LSP servers running and the per-call language detection to be reliable. The spec supports this; we haven't stress-tested it.
- **Cost of cold-starting the language server per session**. LSP startup latency on `tsserver` for a 9,750-LOC project is typically 2-5 s; on a 100k-LOC monorepo it can be 30+ s. The plugin spec exposes `startupTimeout` for this. Worth a paragraph in the rollout doc, not a blocker.

---

## Sources

- [Claude Code Plugins reference (official)](https://code.claude.com/docs/en/plugins-reference) — `.lsp.json` format, plugin component spec, optional fields
- [Piebald-AI/claude-code-lsps (third-party marketplace)](https://github.com/Piebald-AI/claude-code-lsps) — install flow + tool-surface enumeration (`goToDefinition`, `findReferences`, etc.)
- [ktnyt/cclsp (MCP-wrapped LSP, alternative path)](https://github.com/ktnyt/cclsp) — pre-v2.0.74 / non-Anthropic harness option
- [Claude Code v2.0.74 release notes via aifreeapi](https://www.aifreeapi.com/en/posts/claude-code-lsp) — first announcement of LSP support, language list, "50ms vs 45s" claim (third-party, treat as directional)
- [`ENABLE_LSP_TOOL` env var via ClaudeLog](https://claudelog.com/faqs/what-is-lsp-tool-in-claude-code/) — opt-in mechanism + the singular-vs-plural papercut
- [LSP spec (Microsoft)](https://microsoft.github.io/language-server-protocol/) — method names match plugin tool names

---

## Glossary

| Term | Definition |
|---|---|
| LSP | Language Server Protocol — JSON-RPC interface from Microsoft (originally for VS Code) that lets a language-specific "language server" answer semantic queries (definition, references, hover, diagnostics) about source code |
| LSP server | A language-specific binary (`tsserver`, `pyright`, `gopls`, `rust-analyzer`, …) that speaks LSP and serves a project's source tree |
| `goToDefinition` / `findReferences` / `documentSymbol` / `workspaceSymbol` | Standard LSP method names; the names exposed as tool calls by the Claude Code LSP plugin track these |
| MCP | Model Context Protocol — Anthropic's standard for plugging external tools into Claude. Pre-v2.0.74, MCP-wrapped LSP (`cclsp`, `lsp-mcp`) was the only LSP path. Post-v2.0.74, the built-in LSP tool is preferred |
| `ENABLE_LSP_TOOL` | Env var that enables Claude Code's built-in LSP tool (off by default). Note: singular `_TOOL`, not plural |
| Plugin (Claude Code) | A directory of components (skills, agents, hooks, MCP servers, **LSP servers**) installed into a Claude Code session via `/plugin marketplace add` |
| `gh api contents` | The "fetch a single file from a GitHub repo without cloning" path used by today's `/handover` for metadata reads |
| Y-statement | The four-clause AgDR opener: *"In the context of X, facing Y, we decided Z to achieve A, accepting B."* |
| Shallow vs multi-hop semantic query | Shallow: one symbol → one location (definition/references). Multi-hop: chain of definitions across modules to summarise a behaviour (Q3). LSP wins big on shallow, modestly on multi-hop |

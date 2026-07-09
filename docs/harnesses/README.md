# Harness support

An **agent harness** is the CLI/IDE runtime that actually drives an ApexYard session — Claude Code, Codex, pi, opencode, Cursor. ApexYard was built for Claude Code first, and Claude Code is still the only harness where the whole experience is native. But the framework's mechanical enforcement layer — the merge gate, ticket-first edits, secrets scanning, red-CI blocking — is **portable bash**, not Claude-Code-specific, so it can be reached from other harnesses through thin adapters. This directory is the honest, per-harness "what works where, today" breakdown.

> **Not a rebrand.** The primary tagline is still **"for Claude Code."** These pages document the engineering reality (a Codex adapter is merged; pi/opencode/Cursor adapters are in flight) without claiming a multi-harness experience the framework hasn't live-proven yet. See [Rebrand trigger](#rebrand-trigger) below for the exact condition that flips the headline.

## Support matrix

Three maturity tiers, so a column says exactly what it means:

- **Native** — the harness runs the full framework as-is, gates enforced live on every tool call.
- **Adapter — live conformance pending** — an adapter exists and delegates gate decisions to the unmodified bash hooks; the transport is proven by construction/tests, but a live, credentialed end-to-end run (a real model turn actually blocked by a gate) hasn't been recorded yet.
- **Planned** — scoped in a tracking ticket, adapter not yet shipped.

| Harness | Advisory governance (framing, conventions, roles) | Mechanical gates (merge / ticket-first / secrets / red-CI) | Status |
|---------|----------------------------------------------------|------------------------------------------------------------|--------|
| **Claude Code** | Native — `CLAUDE.md` auto-loads at session start; all rules, 65 skills, and 25 agents are first-class | **Enforced live** — the bash hooks fire on `PreToolUse` / `PostToolUse` / `SessionStart` | **Native, full experience** |
| **Codex** | Generated — `.claude/skills/` → `.agents/skills/`, `.claude/agents/*.md` → `.codex/agents/*.toml` | **Delegated** — generated `.codex/hooks.json` execs the *unmodified* `.claude/hooks/*.sh`; block-on-`exit 2` preserved | **Adapter merged** (#730, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)); live Codex-runtime conformance test pending |
| **pi** (pi.dev) | `AGENTS.md` + `SYSTEM.md` advisory bridge, auto-loaded from cwd (#805) | **Delegated** — one dispatcher extension registers on pi's `tool_call` event and shells out to the *unmodified* bash hooks (#815, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)) | **Adapter shipped; live model-turn conformance pending** ([`pi.md`](pi.md)) |
| **opencode** | Planned — `AGENTS.md` bridge | **Delegated** — plugin over the bash hooks (planned) | **Planned** (#821) |
| **Cursor** | Planned — `AGENTS.md` / rules bridge | **Delegated** — generated `.cursor/hooks.json` delegating to the bash hooks, native `exit 2` / failClosed (planned) | **Planned** (#831) |

The honest asterisk that applies to **every** non-Claude row: the adapters keep bash as the single source of truth for gate *decisions*, but whether a given harness's live internal event dispatch invokes the hook at the right moment during a real model turn is the last hop each adapter still has to prove with credentials. Codex and pi have the transport proven and tested; the credentialed live run is the open item for both.

## Shared-core architecture

Everything above rests on four load-bearing decisions:

1. **Gates stay portable bash — they are not ported per harness.** The `.claude/hooks/*.sh` scripts (merge gates, red-CI block, ticket-first, secrets/leak-protection) are the framework's security-critical trust chain. Rewriting them in a per-harness language would fork the gate logic and re-trigger a full security review per file. Instead, every harness reaches the *same* unmodified scripts. Rationale and the rejected language-port options: [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md).
2. **`.claude/` is the canonical authoring surface.** Skills, agents, hooks, settings, rules, and templates are authored under `.claude/` first. Adapter surfaces (`.agents/`, `.codex/`, `harness-adapters/pi/`, a future `.cursor/`) are *generated from* or *shell out to* `.claude/` — never a second hand-maintained copy. This is why adding a gate is a one-place change.
3. **Harnesses are transports, not forks.** An adapter's job is to carry a tool call from the harness's event model into the bash hook's stdin/exit-code contract and back. It carries no governance logic of its own. A bug in an adapter can fail to *invoke* a gate; it cannot silently *change* a gate's decision, because the decision lives in bash.
4. **Model tiers resolve through one matrix.** Framework agent frontmatter uses Claude model-tier labels (`opus` / `sonnet` / `haiku`). Each harness maps those to its own concrete models via a single file, [`.claude/harness-models.json`](../../.claude/harness-models.json) — the Codex adapter reads the `codex` column; a pi/opencode adapter adds its own column rather than hardcoding a second mapping. Per [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md), each harness's `opus` row must stay on that harness's strongest available model — the reasoning-layer reviewers (Rex, Hakim, Tariq, Naqid) have a frontier-model floor and are never downgraded when a harness is added. See [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) for how the Codex generator consumes the matrix.

The upshot: mechanical governance is model- and harness-agnostic and self-hostable, while review *depth* keeps a frontier-model floor. Those two facts are decided in AgDR-0086/0087/0088 and 0082, not asserted here.

## Per-harness pages

### Claude Code

The default and reference harness. No adapter page — the whole repo is its documentation. `CLAUDE.md` is the entry point; the [`.claude/` integration model](../getting-started.md) explains how hooks, agents, and skills wire together.

### Codex

Adapter **merged**. The generator (`bin/sync-codex-adapter.sh`) emits Codex-facing skills, agents, and hook wiring from `.claude/`, with the generated `hooks.json` delegating gate execution to the unmodified bash hooks. Full generate / drift-check / tracking-policy workflow: **[`docs/codex-adapter.md`](../codex-adapter.md)** (kept at its existing path; linked, not moved). Decision record: [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md).

### pi (pi.dev)

Adapter **shipped**; live model-turn conformance is the open item. pi is a deliberately minimal harness — no `CLAUDE.md` auto-load, no hook plumbing, no slash-command runner — so ApexYard supplies both halves of governance: the *instructions* via the `AGENTS.md` / `SYSTEM.md` advisory bridge, and the *mechanical gates* via a single dispatcher extension (`harness-adapters/pi/`) that shells out to the same bash hooks. Full today-vs-not-yet breakdown, install shape, and the one remaining verification gap: **[`pi.md`](pi.md)**. Decision record: [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md).

### opencode

**Planned** — tracked by **#821**. A spike proved the adapter-over-bash pattern viable for opencode; the shipped adapter will be a plugin that maps opencode's tool-call events to the bash hooks' stdin/exit-code contract, same shape as the pi dispatcher. No adapter code in-repo yet.

### Cursor

**Planned** — tracked by **#831**. Cursor supports repo-local hooks with native `exit 2` blocking, so the adapter will *generate* a `.cursor/hooks.json` (the declarative shape, like Codex) that delegates to the bash hooks with failClosed semantics. No adapter code in-repo yet.

## Adapter-authoring pattern for future harnesses

Every adapter answers the same question — *how does this harness let a pre-tool gate block an action, and how do I route that to the bash hooks without duplicating their logic?* Two shapes have emerged, chosen by how the target harness consumes hook configuration:

- **Declarative-generate** — for harnesses that read a static hook-config file (Codex's `.codex/hooks.json`, Cursor's `.cursor/hooks.json`). Write a generator that reads `.claude/settings.json` + `.claude/agents/*` and emits the harness's native config, with each `command` still exec'ing the unmodified `.claude/hooks/*.sh`. Compile any Claude-Code-specific handler metadata (e.g. handler-level `if` predicates) into a shell-side preflight in the generated command. Ship the *generator and its tests* as the durable contribution; treat the generated tree as regenerable output. Reference: the Codex generator (`bin/sync-codex-adapter.sh`, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)).
- **Live extension** — for harnesses with an imperative plugin/extension API (pi's `tool_call` event; opencode's plugin hooks). Write one dispatcher extension driven by a gate table: on each tool call, reconstruct the exact stdin JSON the bash hook expects, spawn the hook, and map its exit code (`2` = block, `0` = allow) to the harness's block/allow return contract. One dispatcher, N gates as data rows — adding a gate is a table entry, not a new file. Reference: the pi dispatcher (`harness-adapters/pi/src/gate-dispatcher.ts`, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)).

In both shapes the non-negotiable is the same: **bash owns every gate decision.** The adapter is the wire, never the judge. And both shapes carry the same last-mile obligation — a live, credentialed end-to-end run proving the harness invokes the gate at the right moment during a real model turn, not just a by-construction test of the transport.

## Rebrand trigger

The headline stays **"for Claude Code"** until this condition is met, verbatim:

> The headline flips to harness-neutral only when **≥2 adapters have live end-to-end conformance proof** (then the site + channel positioning follow in a coordinated pass).

"Live end-to-end conformance proof" means the credentialed run described above: a real model turn under that harness actually blocked by a gate (e.g. an unreviewed merge refused), not a mock or a by-construction test. Today zero adapters have cleared that bar — Codex and pi have the transport proven but the credentialed live run pending — so the framework describes itself as multi-harness *in engineering terms* while keeping the Claude-Code tagline. When the second adapter records that proof, the site (yard.apexscript.com) and channel positioning move in one coordinated pass, not piecemeal.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

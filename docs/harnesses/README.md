# Harness support

An **agent harness** is the CLI/IDE runtime that actually drives an ApexYard session — Claude Code, Codex, pi, opencode, Cursor. ApexYard was built for Claude Code first, and Claude Code is still the only harness where the whole experience is native. But the framework's mechanical enforcement layer — the merge gate, ticket-first edits, secrets scanning, red-CI blocking — is **portable bash**, not Claude-Code-specific, so it can be reached from other harnesses through thin adapters. This directory is the honest, per-harness "what works where, today" breakdown.

> **Not a rebrand.** The primary tagline is still **"for Claude Code."** These pages document the engineering reality — and as of 2026-07-09 that reality includes **three live-proven adapters (opencode, pi, and Codex)**: a real model turn under each was actually blocked by a delegated bash gate. That clears the rebrand trigger's ≥2-live-proven condition, but the headline flip is a **separate, coordinated decision** and hasn't been made — the tagline stays "for Claude Code" until it is. See [Rebrand trigger](#rebrand-trigger) below.

## Support matrix

The one question this answers: **"I use tool X — does ApexYard enforce my rules on it, and what do I do?"** A tool is only marked **proven** when a real, credentialed agent turn on it was actually stopped by the same unmodified bash rule — not a mock, not a by-construction test.

| Tool | Enforces your rules? | Setup | Good to know |
|------|----------------------|-------|--------------|
| **Claude Code** | ✅ **Yes — natively.** The rules fire on every tool call; no adapter. | Nothing to install — `/setup`; `.claude/` is auto-picked-up. | The reference tool: `CLAUDE.md` auto-loads, and all rules, skills, and agents are first-class. |
| **opencode** | ✅ **Yes — proven (2026-07-09).** A real `opencode run --auto` turn's `git add -A` was blocked by the same rule. | `bash bin/install-opencode-adapter.sh` → `.opencode/plugins/apexyard/` | Run with `--auto` so the command reaches the rule. The plugin reads its rule list straight from `.claude/settings.json`, so it can't drift. Details: [opencode.md](opencode.md), [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md). |
| **pi** (pi.dev) | ✅ **Yes — proven (2026-07-09).** A real `pi -p -a` turn was stopped the same way. | `bash bin/install-pi-adapter.sh` → `.pi/extensions/apexyard/` | Run headless with `-a` / `--approve`. pi ships deliberately bare-bones and leaves governance to you — ApexYard is that layer. An `AGENTS.md` + `SYSTEM.md` bridge carries the advisory rules. Details: [pi.md](pi.md), [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md). |
| **Codex** | ✅ **Yes — proven (2026-07-09).** A real `codex exec -m gpt-5.5` turn's `git add -A` fired the same rule (clean exit 2, nothing staged). | `bash bin/sync-codex-adapter.sh` → generates `.codex/hooks.json` | Codex has to trust the rules once — `/hooks` (interactive), `--dangerously-bypass-hook-trust` (one-off), or a user-level `~/.codex/hooks.json`. That's a trust step, not a missing capability. Details: [codex.md](codex.md), [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md). |
| **Cursor** | 🟡 **Partly — not proven.** It blocks the command, but by *failing safe* when its rule-runner errors, not by actually running our rule. | `bash bin/install-cursor-adapter.sh` → user-level `~/.cursor/hooks.json` | Works in the Cursor **IDE** only — the `cursor-agent` CLI ignores hooks (it uses its own permissions model). Two real limits found on test: the CLI path, and that IDE 3.x loads hooks only from **user-level** `~/.cursor/hooks.json`. Even loaded, the block came from failing safe — not the same as the three proven tools. Details: [cursor.md](cursor.md). |

**The pattern underneath.** The rule is always the *same* unmodified bash; what changes per tool is one small setting that lets the agent's command reach it — an approve/trust flag (opencode `--auto`, pi `-a`, Codex trust) or a config location. Once that's set, the delegated `.claude/hooks/*.sh` runs and returns the identical block on every tool. Cursor is the exception: its rule-runner can't cleanly run an external command mid-turn, so it only fails safe rather than running the rule.

## Shared-core architecture

Everything above rests on four load-bearing decisions:

1. **Gates stay portable bash — they are not ported per harness.** The `.claude/hooks/*.sh` scripts (merge gates, red-CI block, ticket-first, secrets/leak-protection) are the framework's security-critical trust chain. Rewriting them in a per-harness language would fork the gate logic and re-trigger a full security review per file. Instead, every harness reaches the *same* unmodified scripts. Rationale and the rejected language-port options: [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md).
2. **`.claude/` is the canonical authoring surface.** Skills, agents, hooks, settings, rules, and templates are authored under `.claude/` first. Adapter surfaces (`.agents/`, `.codex/`, `harness-adapters/pi/`, a future `.cursor/`) are *generated from* or *shell out to* `.claude/` — never a second hand-maintained copy. This is why adding a gate is a one-place change.
3. **Harnesses are transports, not forks.** An adapter's job is to carry a tool call from the harness's event model into the bash hook's stdin/exit-code contract and back. It carries no governance logic of its own. A bug in an adapter can fail to *invoke* a gate; it cannot silently *change* a gate's decision, because the decision lives in bash.
4. **Model tiers resolve through one matrix.** Framework agent frontmatter uses Claude model-tier labels (`opus` / `sonnet` / `haiku`). Each harness maps those to its own concrete models via a single file, [`.claude/harness-models.json`](../../.claude/harness-models.json) — the Codex adapter reads the `codex` column; a pi/opencode adapter adds its own column rather than hardcoding a second mapping. Per [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md), each harness's `opus` row must stay on that harness's strongest available model — the reasoning-layer reviewers (Rex, Hakim, Tariq, Naqid) have a frontier-model floor and are never downgraded when a harness is added. See [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md) for how the Codex generator consumes the matrix.

The upshot: mechanical governance is model- and harness-agnostic and self-hostable, while review *depth* keeps a frontier-model floor. Those two facts are decided in AgDR-0086/0087/0088 and 0082, not asserted here.

## Per-harness pages

Each harness has a dedicated page with a consistent skeleton — status, what's enforced vs advisory today, how the transport works, how to install/generate, gaps + tracking, and related AgDRs.

- **[Claude Code](claude-code.md)** — Native, full experience. The reference harness: `CLAUDE.md` auto-load, hooks firing live, slash-command skills, sub-agents, session markers. Install pointer: [`docs/getting-started.md`](../getting-started.md).
- **[opencode](opencode.md)** — ✅ **Live-proven (2026-07-09)**. A TypeScript plugin over the unmodified bash hooks with `settings.json`-derived gates (drift-proof by construction); a real `opencode run --auto` turn's `git add -A` was refused by the delegated `block-git-add-all.sh`. Install: `bash bin/install-opencode-adapter.sh` (subdir shape, #845). Precondition: `--auto`.
- **[pi (pi.dev)](pi.md)** — ✅ **Live-proven (2026-07-09)**. A single dispatcher extension shells out to the bash hooks; a real `pi -p -a` turn was blocked the same way. The `AGENTS.md`/`SYSTEM.md` advisory bridge works today. Install: `bash bin/install-pi-adapter.sh` (`.pi/extensions/apexyard/`, #845). Precondition: headless `-a`/`--approve`.
- **[Codex](codex.md)** — ✅ **Live-proven (2026-07-09)**. Generated from `.claude/`; a real `codex exec --dangerously-bypass-hook-trust -m gpt-5.5` turn's `git add -A` fired the delegated `block-git-add-all.sh` cleanly (exit 2, nothing staged). Model mapping (`opus`→`gpt-5.5`) is correct. Precondition: **hook-trust** — `/hooks` (interactive), `--dangerously-bypass-hook-trust` (headless one-off), or user-level `~/.codex/hooks.json`. Full workflow in [`docs/codex-adapter.md`](../codex-adapter.md) (linked, not moved).
- **[Cursor](cursor.md)** — 🟡 **failClosed-only**. Adapter merged (PR #838, AgDR-0091), but live-tested this round: the `cursor-agent` CLI ignores `hooks.json`, and Cursor IDE 3.x loads hooks only from **user-level** `~/.cursor/hooks.json`, where the observed block was `failClosed`, not verified delegated execution. Not live-proven; generator/install fix tracked separately. Full workflow in [`docs/cursor-adapter.md`](../cursor-adapter.md).

## Adapter-authoring pattern for future harnesses

Every adapter answers the same question — *how does this harness let a pre-tool gate block an action, and how do I route that to the bash hooks without duplicating their logic?* Two shapes have emerged, chosen by how the target harness consumes hook configuration:

- **Declarative-generate** — for harnesses that read a static hook-config file (Codex's `.codex/hooks.json`, Cursor's `.cursor/hooks.json`). Write a generator that reads `.claude/settings.json` + `.claude/agents/*` and emits the harness's native config, with each `command` still exec'ing the unmodified `.claude/hooks/*.sh`. Compile any Claude-Code-specific handler metadata (e.g. handler-level `if` predicates) into a shell-side preflight in the generated command. Ship the *generator and its tests* as the durable contribution; treat the generated tree as regenerable output. Reference: the Codex generator (`bin/sync-codex-adapter.sh`, [AgDR-0088](../agdr/AgDR-0088-codex-adapter-generation.md)).
- **Live extension** — for harnesses with an imperative plugin/extension API (pi's `tool_call` event; opencode's plugin hooks). Write one dispatcher extension driven by a gate table: on each tool call, reconstruct the exact stdin JSON the bash hook expects, spawn the hook, and map its exit code (`2` = block, `0` = allow) to the harness's block/allow return contract. One dispatcher, N gates as data rows — adding a gate is a table entry, not a new file. Reference: the pi dispatcher (`harness-adapters/pi/src/gate-dispatcher.ts`, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)).

In both shapes the non-negotiable is the same: **bash owns every gate decision.** The adapter is the wire, never the judge. And both shapes carry the same last-mile obligation — a live, credentialed end-to-end run proving the harness invokes the gate at the right moment during a real model turn, not just a by-construction test of the transport.

## Rebrand trigger

The headline stays **"for Claude Code"** until this condition is met, verbatim:

> The headline flips to harness-neutral only when **≥2 adapters have live end-to-end conformance proof** (then the site + channel positioning follow in a coordinated pass).

"Live end-to-end conformance proof" means the credentialed run described above: a real model turn under that harness actually blocked by a gate (e.g. a `git add -A` refused by the unmodified bash hook), not a mock or a by-construction test.

**As of 2026-07-09 the trigger condition is MET** — three adapters (**opencode**, **pi**, and **Codex**) have recorded that proof. That does **not** auto-flip the headline: the flip is a **separate, deliberate decision** that moves the site (yard.apexscript.com) and channel positioning in one coordinated pass, and it hasn't been taken. Until it is, the framework keeps the Claude-Code tagline and describes multi-harness support in the precise, per-harness terms above rather than as a blanket claim. (Cursor remains below the bar — it fails closed rather than running the delegated gate — so the count is opencode + pi + Codex, not all four.)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

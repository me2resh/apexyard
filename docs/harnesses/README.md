# Harness support

An **agent harness** is the CLI/IDE runtime that actually drives an ApexYard session — Claude Code, Codex, pi, opencode, Cursor. ApexYard was built for Claude Code first, and Claude Code is still the only harness where the whole experience is native. But the framework's mechanical enforcement layer — the merge gate, ticket-first edits, secrets scanning, red-CI blocking — is **portable bash**, not Claude-Code-specific, so it can be reached from other harnesses through thin adapters. This directory is the honest, per-harness "what works where, today" breakdown.

> **Not a rebrand.** The primary tagline is still **"for Claude Code."** These pages document the engineering reality — and as of 2026-07-09 that reality includes **three live-proven adapters (opencode, pi, and Codex)**: a real model turn under each was actually blocked by a delegated bash gate. That clears the rebrand trigger's ≥2-live-proven condition, but the headline flip is a **separate, coordinated decision** and hasn't been made — the tagline stays "for Claude Code" until it is. See [Rebrand trigger](#rebrand-trigger) below.

## Support matrix

Four maturity tiers, so a column says exactly what it means:

- **Native** — the harness runs the full framework as-is, gates enforced live on every tool call.
- **✅ Live-proven** — a credentialed, real model turn under the harness was actually blocked by a delegated bash gate (not a mock, not a by-construction test). Recorded date in the row.
- **⏳ Pending live verification** — an adapter exists and delegates gate decisions to the unmodified bash hooks; the transport is tested in-repo, but a credentialed live run hasn't confirmed the harness invokes the hook at the right moment during a real turn.
- **🟡 failClosed-only** — the harness blocks a gated action, but by *failing closed* on a hook-runner error rather than by verified delegated execution of the bash gate; not equivalent to a live-proven delegated block.

| Harness | Advisory governance (framing, conventions, roles) | Mechanical gates (merge / ticket-first / secrets / red-CI) | Install | Live-enforcement status |
|---------|----------------------------------------------------|------------------------------------------------------------|---------|-------------------------|
| **Claude Code** | Native — `CLAUDE.md` auto-loads at session start; all rules, 65 skills, and 25 agents are first-class | **Enforced live** — the bash hooks fire on `PreToolUse` / `PostToolUse` / `SessionStart` | Native — `/setup`; `.claude/` auto-picked-up | **Native, full experience** |
| **opencode** | `AGENTS.md` bridge | **Delegated** — `harness-adapters/opencode/` plugin derives its gate table from `.claude/settings.json` at load and execs the *unmodified* bash hooks; throw = deny, fail-closed on execution failure (PR #839, [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md)) | `bash bin/install-opencode-adapter.sh` → `.opencode/plugins/apexyard/` (#845) | ✅ **Live-proven (2026-07-09)** — a real `opencode run --auto` turn's `git add -A` was blocked by the delegated `block-git-add-all.sh` ([`opencode.md`](opencode.md)) |
| **pi** (pi.dev) | `AGENTS.md` + `SYSTEM.md` advisory bridge, auto-loaded from cwd (#805) | **Delegated** — one dispatcher extension registers on pi's `tool_call` event and shells out to the *unmodified* bash hooks (#815, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)) | `bash bin/install-pi-adapter.sh` → `.pi/extensions/apexyard/` (#845) | ✅ **Live-proven (2026-07-09)** — a real `pi -p -a` turn was blocked the same way ([`pi.md`](pi.md)) |
| **Codex** | Generated — `.claude/skills/` → `.agents/skills/`, `.claude/agents/*.md` → `.codex/agents/*.toml` | **Delegated** — generated `.codex/hooks.json` execs the *unmodified* `.claude/hooks/*.sh`; block-on-`exit 2` preserved | `bin/sync-codex-adapter.sh` → `.codex/hooks.json` (trust required) | ✅ **Live-proven (2026-07-09)** — a real `codex exec --dangerously-bypass-hook-trust -m gpt-5.5` turn's `git add -A` fired the delegated `block-git-add-all.sh` (clean exit 2, nothing staged) ([`codex.md`](codex.md)) |
| **Cursor** | Generated `.cursor/rules/apexyard.mdc` bridge | **Delegated** — generated `.cursor/hooks.json`; native `exit 2` deny, `failClosed:true` on the security-critical gates (PR #838, [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md)) | `bin/sync-cursor-adapter.sh` → **user-level** `~/.cursor/hooks.json` (see [`cursor.md`](cursor.md)) | 🟡 **failClosed-only** — Cursor IDE 3.x enforces via `failClosed`, not verified delegated execution; the `cursor-agent` CLI ignores `hooks.json` entirely (#840, [`cursor.md`](cursor.md)) |

The honest asterisk, now **per-harness** — and the real lesson is a **precondition pattern**, not a capability split between adapters:

> **Every adapter enforces live in headless with the right trust/location precondition — opencode (`--auto`), pi (`-a`/`--approve` or user-level install), Codex (hook-trust: `/hooks`, `--dangerously-bypass-hook-trust`, or user-level `~/.codex/hooks.json`). Three are live-proven on that basis. The one outlier is Cursor.**
>
> The gate always lives in the same unmodified bash; what differs per harness is the *precondition to let the tool call reach it* — an approval/trust flag or a config location. Once that precondition is met, the delegated `.claude/hooks/*.sh` runs and returns exit 2 identically. Cursor is the exception: its hook-runner can't cleanly exec an external command in agent mode (a `MainThreadShellExec` limitation), so it only *fails closed* instead of running the delegated gate, and the `cursor-agent` CLI ignores hooks entirely.

- **opencode + pi + Codex are live-proven (2026-07-09).** The last hop — the harness's live internal dispatch actually invoking the delegated bash hook mid-turn — has been observed with credentials for all three: a real `git add -A` refused by the unmodified gate, verbatim hook output, nothing staged. Each needs its precondition so the tool call reaches the gate — opencode `--auto`, pi headless `-a`/`--approve`, Codex hook-trust (`/hooks` interactive, `--dangerously-bypass-hook-trust` headless one-off, or user-level `~/.codex/hooks.json`). Codex's is a **trust** gap, not a capability gap: project-local hooks load only when the `.codex/` layer is trusted; with trust granted, `codex exec -m gpt-5.5` fires the delegated hook cleanly, equivalent to opencode/pi.
- **Cursor blocks, but only via failClosed at user level.** Two hard findings: the `cursor-agent` CLI does **not** run `hooks.json` (it uses its own `cli-config` permissions model), and Cursor IDE 3.x loads hooks only from **user-level** `~/.cursor/hooks.json`, not the project `.cursor/hooks.json` the generator emitted. Even loaded at user level, the observed block came from `failClosed:true` on a hook-runner error — the delegated `.claude/hooks/*.sh` did not cleanly execute — so it is **not** equivalent to the three delegated-execution proofs. See [`cursor.md`](cursor.md); the generator/install fix is tracked separately.

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

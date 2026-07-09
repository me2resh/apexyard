# Harness support — pi (pi.dev)

**Status:** ✅ **Live-proven (2026-07-09)** — a real `pi -p -a` model turn was blocked by the delegated bash gate (a `git add`-class command refused by the unmodified hook, exit 2, nothing staged). Adapter shipped (`harness-adapters/pi/`, #815, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)); install shape hardened in #845.

## What's verified

A credentialed pi session in headless mode (`pi -p -a`) issued a gated command during a real model turn and the delegated `.claude/hooks/*.sh` gate refused it — the same hook Claude Code runs. That is the live end-to-end conformance proof the [rebrand trigger](README.md#rebrand-trigger) requires, and pi is one of three adapters (with opencode and Codex) that cleared it.

**How pi reaches the gate:** like opencode, pi exposes an **imperative extension API** — the dispatcher registers on pi's `tool_call` event, so the gate runs inside the real turn. Its precondition for enforcement is headless `-a`/`--approve` (project trust, so the tool call reaches the handler) — the pi analog of opencode's `--auto` and Codex's hook-trust. Every apexyard adapter enforces in headless once its precondition is met; Cursor is the one exception (see the [harness index](README.md#support-matrix)).

apexyard's governance was built for Claude Code first: `CLAUDE.md` is auto-loaded at session start, `.claude/hooks/*.sh` mechanically enforce the merge gate / ticket-first / secrets-scan rules, and `.claude/skills/*.md` become typed slash commands. **pi** (pi.dev — Earendil's minimal, unopinionated agent CLI) is a deliberately different shape: no `CLAUDE.md`-style auto-load, no hook plumbing, no MCP, no slash-command runner, no plan mode, no background bash, no permission popups. Pi pushes that governance layer to user-installed packages instead of building it in. **apexyard is exactly that layer for a pi user.**

This doc is the honest today-vs-not-yet breakdown for running apexyard-governed work under pi — updated as of me2resh/apexyard#815 (the shipped adapter) and the 2026-07-09 live proof that closed the last "not yet" this doc used to carry. See me2resh/apexyard#805 (the `AGENTS.md` advisory bridge), me2resh/apexyard#804 (the spike that proved the enforcement pattern viable), me2resh/apexyard#815 (the shipped adapter), and me2resh/apexyard#845 (the hardened install shape).

## What works today

| Capability | How it reaches pi |
|------------|--------------------|
| Chief-of-Staff framing + SDLC | `AGENTS.md` § "Operator governance bridge" — pi auto-loads `AGENTS.md` from cwd (or `~/.pi/agent/`), the same convention Cursor/Aider/Cline use |
| Load-bearing conventions (branch/PR/commit format, ticket vocabulary, one-ticket-at-a-time, plan-before-risky-work, reporting style, no secrets, no direct-`main`) | Inlined concisely in `AGENTS.md`, with the full text of each rule at `.claude/rules/*.md` — pi can `Read` those on request |
| Role definitions + activation triggers | `roles/*.md` + `.claude/rules/role-triggers.md` — readable, no auto-fire banner (see "not yet" below) |
| Skills (ticket filing, audits, releases, …) | `.claude/skills/<name>/SKILL.md` are plain markdown processes — invoke by reading the file and following it step by step; there's no slash-command mechanism to trigger them automatically |
| Operating-posture priming | `SYSTEM.md` — a short custom system prompt pi reads alongside `AGENTS.md`, pointing back at it rather than duplicating it |
| AgDR / templates / workflows docs | All plain markdown under `docs/agdr/`, `templates/`, `workflows/` — readable exactly as they are for any harness |
| **Mechanical gate enforcement** — the two-marker merge gate, red-CI merge blocking, design/architecture review gates, secrets scanning, ticket-first / migration-ticket-first edit blocking | `harness-adapters/pi/` — a single dispatcher extension registers on pi's `tool_call` event and shells out to the **same, unmodified** `.claude/hooks/*.sh` scripts Claude Code uses, mapping each hook's exit code to pi's `{block, reason}` contract. Zero logic duplication — bash stays the one source of truth. See `harness-adapters/pi/README.md` and `docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md`. |

## Preconditions

- **Headless needs `-a` / `--approve`** (e.g. `pi -p -a`). That grants project trust so the tool call actually reaches the dispatcher's `tool_call` handler; without it pi may resolve the action before the gate sees it. `-a` is the precondition the live proof ran under.
- Loaded from inside an apexyard ops fork, or with the `APEXYARD_OPS_ROOT` override documented in `harness-adapters/pi/README.md` when running outside the fork's working tree.

## What does NOT work yet

| Gap | Why | Tracked as |
|-----|-----|-----------|
| **MCP-backed code/docs search** (`apexyard-search`) | Pi's design omits MCP entirely | No dedicated ticket — falls back to plain `grep`/`Read`, which is slower but functionally equivalent |
| **Role-trigger advisory banners** | Claude Code's `detect-role-trigger.sh` posts a `PreToolUse` reminder banner when a diff matches a role trigger (e.g. touching `**/auth/**`). Pi has no hook to run that check | Self-check `.claude/rules/role-triggers.md` manually |
| **Slash-command UX** for skills | Pi has no command-registration mechanism; skills are invoked by reading their `SKILL.md` and following the process by hand | Not tracked — an ergonomics gap, not a governance one |
| **Plan mode, background bash, permission popups** | Deliberately absent from pi's design, not apexyard-specific gaps | N/A — approximate with an explicit "here's my plan, confirming before I execute" pause where `.claude/rules/plan-mode.md` would otherwise apply |
| **Claude Code's session-pin protection against wrong-ops-root resolution** (apexyard#381) | pi has no `CLAUDE_CODE_SESSION_ID` / SessionStart-hook equivalent to write the pin | Use the `APEXYARD_OPS_ROOT` env var override documented in `harness-adapters/pi/README.md` when running pi outside the ops fork's own working tree |

## The honest summary

A pi user gets both halves of apexyard's governance: the **instructions** (via `AGENTS.md`/`SYSTEM.md`, unchanged since #805) and, as of #815, the same **mechanical gates** Claude Code enforces — an ungated action is refused by the real bash hook running underneath pi, not just discouraged in prose. As of 2026-07-09 that enforcement is **live-proven**: the "does pi's live internal dispatch really call the handler this way" hop that this doc used to list as its one asterisk has now been observed inside a credentialed `pi -p -a` session, not just proven by construction. The only thing between an adopter and enforcement is the `-a` precondition above.

## How to install

```bash
bash bin/install-pi-adapter.sh
```

That writes the adapter into `.pi/extensions/apexyard/` — a **subdirectory** shape (confirmed against pi 0.80.3, #844/#845). pi's local-extension discovery scans `.pi/extensions/` and requires every `.ts` file it finds to export a valid default factory; a flat `cp` of the dispatcher plus its helper modules makes pi try to load each helper as an independent extension and fails the session. The install script produces the one-subdirectory-behind-an-`index.ts`-shim layout mechanically (and rewrites the one shared-core import path). Then run `pi` from the project containing `.pi/extensions/` — it auto-discovers `.pi/extensions/apexyard/index.ts`.

Orientation docs (`AGENTS.md` + `SYSTEM.md`) auto-load from the fork's cwd with no extra step; see `harness-adapters/pi/README.md` for the manual `--extension` form and the `APEXYARD_OPS_ROOT` override.

## Roadmap

me2resh/apexyard#804 (spike) proved the adapter-over-bash pattern viable; #815 shipped the dispatcher covering the merge gate, red-CI block, design/architecture review, secrets scanning, and ticket-first gates; the 2026-07-09 live run proved it enforces during a real model turn; #845 hardened the install shape. The next steps, not yet scoped as tickets: porting role-trigger advisory banners and/or a slash-command-equivalent skill runner if pi's extension API grows the right hooks for either.

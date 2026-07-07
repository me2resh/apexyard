# Harness support — pi (pi.dev)

apexyard's governance was built for Claude Code first: `CLAUDE.md` is auto-loaded at session start, `.claude/hooks/*.sh` mechanically enforce the merge gate / ticket-first / secrets-scan rules, and `.claude/skills/*.md` become typed slash commands. **pi** (pi.dev — Earendil's minimal, unopinionated agent CLI) is a deliberately different shape: no `CLAUDE.md`-style auto-load, no hook plumbing, no MCP, no slash-command runner, no plan mode, no background bash, no permission popups. Pi pushes that governance layer to user-installed packages instead of building it in. **apexyard is exactly that layer for a pi user.**

This doc is the honest today-vs-not-yet breakdown for running apexyard-governed work under pi — updated as of me2resh/apexyard#815, which closes the mechanical-enforcement gap this doc used to list under "not yet". See me2resh/apexyard#805 (the `AGENTS.md` advisory bridge), me2resh/apexyard#804 (the spike that proved the enforcement pattern viable), and me2resh/apexyard#815 (the shipped adapter).

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

## What does NOT work yet

| Gap | Why | Tracked as |
|-----|-----|-----------|
| **A live, model-driven pi agent turn actually triggering the gate adapter's `tool_call` handler** | The gate adapter's transport (stdin reconstruction, hook exec, exit-code mapping) is proven live against the real bash hooks and real GitHub state; whether pi's *internal* event dispatch calls handlers with matching event shapes during a real model turn needs pi model credentials, which weren't available when #815 was built | me2resh/apexyard#815 § "Known gaps" — run the documented live-verification step once credentials are available |
| **MCP-backed code/docs search** (`apexyard-search`) | Pi's design omits MCP entirely | No dedicated ticket — falls back to plain `grep`/`Read`, which is slower but functionally equivalent |
| **Role-trigger advisory banners** | Claude Code's `detect-role-trigger.sh` posts a `PreToolUse` reminder banner when a diff matches a role trigger (e.g. touching `**/auth/**`). Pi has no hook to run that check | Self-check `.claude/rules/role-triggers.md` manually |
| **Slash-command UX** for skills | Pi has no command-registration mechanism; skills are invoked by reading their `SKILL.md` and following the process by hand | Not tracked — an ergonomics gap, not a governance one |
| **Plan mode, background bash, permission popups** | Deliberately absent from pi's design, not apexyard-specific gaps | N/A — approximate with an explicit "here's my plan, confirming before I execute" pause where `.claude/rules/plan-mode.md` would otherwise apply |
| **Claude Code's session-pin protection against wrong-ops-root resolution** (apexyard#381) | pi has no `CLAUDE_CODE_SESSION_ID` / SessionStart-hook equivalent to write the pin | Use the `APEXYARD_OPS_ROOT` env var override documented in `harness-adapters/pi/README.md` when running pi outside the ops fork's own working tree |

## The honest summary

A pi user now gets both halves of apexyard's governance: the **instructions** (via `AGENTS.md`/`SYSTEM.md`, unchanged since #805) and, as of #815, the same **mechanical gates** Claude Code enforces — an ungated merge attempt is refused by the real `block-unreviewed-merge.sh` hook running underneath pi, not just discouraged in prose. The one remaining asterisk is that the final "does pi's live internal dispatch really call the handler this way" hop is proven by construction (a faithful mock matching pi's real, typechecked `.d.ts`) rather than observed inside a live, credentialed pi session — see `harness-adapters/pi/README.md` for exactly what would close that gap.

## Install shape

1. Fork [`me2resh/apexyard`](https://github.com/me2resh/apexyard) (or your existing ops fork) as usual — no pi-specific setup step.
2. `cd` into the fork.
3. Run `pi`. It auto-loads `AGENTS.md` (governance + orientation) and `SYSTEM.md` (operating posture) from the current directory.
4. Install the gate adapter (`cd harness-adapters/pi && npm install`) and load it — `pi --extension harness-adapters/pi/src/gate-dispatcher.ts` — for mechanical enforcement; see `harness-adapters/pi/README.md` for project-local auto-discovery instead.
5. Work as normal — start tickets, open PRs, run skills by reading their `SKILL.md`.

## Roadmap

me2resh/apexyard#804 (spike) proved the adapter-over-bash pattern viable; me2resh/apexyard#815 shipped the dispatcher covering the merge gate, red-CI block, design/architecture review, secrets scanning, and ticket-first gates. The next steps, not yet scoped as tickets: a live-credentialed end-to-end verification of the one remaining gap above, and porting role-trigger advisory banners and/or a slash-command-equivalent skill runner if pi's extension API grows the right hooks for either.

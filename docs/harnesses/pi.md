# Harness support — pi (pi.dev)

apexyard's governance was built for Claude Code first: `CLAUDE.md` is auto-loaded at session start, `.claude/hooks/*.sh` mechanically enforce the merge gate / ticket-first / secrets-scan rules, and `.claude/skills/*.md` become typed slash commands. **pi** (pi.dev — Earendil's minimal, unopinionated agent CLI) is a deliberately different shape: no `CLAUDE.md`-style auto-load, no hook plumbing, no MCP, no slash-command runner, no plan mode, no background bash, no permission popups. Pi pushes that governance layer to user-installed packages instead of building it in. **apexyard is exactly that layer for a pi user.**

This doc is the honest today-vs-not-yet breakdown for running apexyard-governed work under pi. It's the first slice of multi-harness support — see me2resh/apexyard#805 (this bridge) and the sibling me2resh/apexyard#804 (a spike on whether mechanical enforcement can be ported).

## What works today

| Capability | How it reaches pi |
|------------|--------------------|
| Chief-of-Staff framing + SDLC | `AGENTS.md` § "Operator governance bridge" — pi auto-loads `AGENTS.md` from cwd (or `~/.pi/agent/`), the same convention Cursor/Aider/Cline use |
| Load-bearing conventions (branch/PR/commit format, ticket vocabulary, one-ticket-at-a-time, plan-before-risky-work, reporting style, no secrets, no direct-`main`) | Inlined concisely in `AGENTS.md`, with the full text of each rule at `.claude/rules/*.md` — pi can `Read` those on request |
| Role definitions + activation triggers | `roles/*.md` + `.claude/rules/role-triggers.md` — readable, no auto-fire banner (see "not yet" below) |
| Skills (ticket filing, audits, releases, …) | `.claude/skills/<name>/SKILL.md` are plain markdown processes — invoke by reading the file and following it step by step; there's no slash-command mechanism to trigger them automatically |
| Operating-posture priming | `SYSTEM.md` — a short custom system prompt pi reads alongside `AGENTS.md`, pointing back at it rather than duplicating it |
| AgDR / templates / workflows docs | All plain markdown under `docs/agdr/`, `templates/`, `workflows/` — readable exactly as they are for any harness |

## What does NOT work yet

| Gap | Why | Tracked as |
|-----|-----|-----------|
| **Mechanical gate enforcement** — the two-marker merge gate, ticket-first edit blocking, secrets scanning, AgDR-required checks, red-CI merge blocking | These are shell hooks wired to Claude Code's `PreToolUse`/`PostToolUse` events via `.claude/settings.json`. Pi has no equivalent hook-registration surface documented yet, so nothing shells out to `.claude/hooks/*.sh` on pi's behalf | me2resh/apexyard#804 (spike: can a thin pi extension shell out to the existing bash hooks?) |
| **MCP-backed code/docs search** (`apexyard-search`) | Pi's design omits MCP entirely | No dedicated ticket — falls back to plain `grep`/`Read`, which is slower but functionally equivalent |
| **Role-trigger advisory banners** | Claude Code's `detect-role-trigger.sh` posts a `PreToolUse` reminder banner when a diff matches a role trigger (e.g. touching `**/auth/**`). Pi has no hook to run that check | Self-check `.claude/rules/role-triggers.md` manually |
| **Slash-command UX** for skills | Pi has no command-registration mechanism; skills are invoked by reading their `SKILL.md` and following the process by hand | Not tracked — an ergonomics gap, not a governance one |
| **Plan mode, background bash, permission popups** | Deliberately absent from pi's design, not apexyard-specific gaps | N/A — approximate with an explicit "here's my plan, confirming before I execute" pause where `.claude/rules/plan-mode.md` would otherwise apply |

## The honest summary

Today, a pi user gets apexyard's rules **as instructions to follow**, not **as gates that stop them**. That's a real step — it's the difference between a pi session that has no idea apexyard's conventions exist and one that opens with the same Chief-of-Staff framing, SDLC, and ticket discipline a Claude Code session gets from `CLAUDE.md`. It is not parity with Claude Code's mechanical enforcement, and this doc — and `AGENTS.md`'s own "What's NOT bridged yet" section — say so explicitly rather than imply otherwise.

## Install shape

1. Fork [`me2resh/apexyard`](https://github.com/me2resh/apexyard) (or your existing ops fork) as usual — no pi-specific setup step.
2. `cd` into the fork.
3. Run `pi`. It auto-loads `AGENTS.md` (governance + orientation) and `SYSTEM.md` (operating posture) from the current directory.
4. Work as normal — start tickets, open PRs, run skills by reading their `SKILL.md` — with the understanding from "What does NOT work yet" above that nothing here blocks you the way Claude Code's hooks would.

## Roadmap

The natural next step is the spike already filed at me2resh/apexyard#804: prove whether a thin pi extension can fire on pi's tool-call event and shell out to the existing bash gate hooks (e.g. `block-unreviewed-merge.sh`), giving apexyard real mechanical enforcement under pi with a single bash source of truth and a thin per-harness adapter — rather than a from-scratch TypeScript reimplementation of every gate. If that pattern holds, this doc's "not yet" column becomes the next feature ticket; if it doesn't, the spike's disposition memo will say why and name the alternative.

# Harness support: pi (pi.dev)

**Status:** ✅ **Live-proven (2026-07-09)**: the delegated bash gate blocked a real `pi -p -a` model turn. The unmodified hook refused a `git add`-class command (exit 2, nothing staged). Adapter shipped (`harness-adapters/pi/`, #815, [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md)); install shape hardened in #845.

## Verification

A credentialed pi session in headless mode (`pi -p -a`) issued a gated command during a real model turn. The delegated `.claude/hooks/*.sh` gate refused it: the same hook Claude Code runs. That is the live end-to-end conformance proof the [rebrand trigger](README.md#rebrand-trigger) requires, and pi is one of three adapters (with opencode and Codex) that cleared it.

**How pi reaches the gate:** like opencode, pi exposes an **imperative extension API**. The dispatcher registers on pi's `tool_call` event, so the gate runs inside the real turn. Its precondition for enforcement is headless `-a`/`--approve` (project trust, so the tool call reaches the handler): the pi analog of opencode's `--auto` and Codex's hook-trust. Every apexyard adapter enforces in headless once it meets its precondition; Cursor is the one exception (see the [harness index](README.md#support-matrix)).

ApexYard supported Claude Code first: `CLAUDE.md` loads at session start, `.claude/hooks/*.sh` enforce merge, ticket-first, and secrets-scan rules, and `.claude/skills/*.md` become typed slash commands. **pi** (pi.dev, Earendil's minimal, unopinionated agent CLI) has a different shape. It does not auto-load `CLAUDE.md`, provide hook plumbing or MCP, register slash commands, or include plan mode, background bash, or permission popups. Pi leaves that governance layer to user-installed packages. **ApexYard provides that layer for pi users.**

This doc is the honest today-vs-not-yet breakdown for running apexyard-governed work under pi. It reflects me2resh/apexyard#815 (the shipped adapter) and the 2026-07-09 live proof. That proof closed the last "not yet" this doc used to carry. See me2resh/apexyard#805 (the `AGENTS.md` advisory bridge) and me2resh/apexyard#804 (the spike that proved the enforcement pattern viable). Also see me2resh/apexyard#815 (the shipped adapter) and me2resh/apexyard#845 (the hardened install shape).

## What works today

| Capability | How it reaches pi |
|------------|--------------------|
| Chief-of-Staff framing + SDLC | `AGENTS.md` § "Operator governance bridge": pi auto-loads `AGENTS.md` from cwd (or `~/.pi/agent/`), the same convention Cursor/Aider/Cline use |
| Load-bearing conventions (branch/PR/commit format, ticket vocabulary, one-ticket-at-a-time, plan-before-risky-work, reporting style, no secrets, no direct-`main`) | Inlined concisely in `AGENTS.md`, with the full text of each rule at `.claude/rules/*.md`: pi can `Read` those on request |
| Role definitions + activation triggers | `roles/*.md` + `.claude/rules/role-triggers.md`: readable, no auto-fire banner (see "not yet" below) |
| Skills (ticket filing, audits, releases, …) | `.claude/skills/<name>/SKILL.md` are plain markdown processes: invoke by reading the file and following it step by step; there is no slash-command mechanism to trigger them automatically |
| Operating-posture priming | `SYSTEM.md`: a short custom system prompt pi reads alongside `AGENTS.md`, pointing back at it rather than duplicating it |
| AgDR / templates / workflows docs | All plain markdown under `docs/agdr/`, `templates/`, `workflows/`: readable exactly as they are for any harness |
| **Mechanical gate enforcement**: the two-marker merge gate, red-CI merge blocking, design/architecture review gates, secrets scanning, ticket-first / migration-ticket-first edit blocking | `harness-adapters/pi/`: a single dispatcher extension registers on pi's `tool_call` event. It shells out to the **same, unmodified** `.claude/hooks/*.sh` scripts Claude Code uses, mapping each hook's exit code to pi's `{block, reason}` contract. Zero logic duplication: bash stays the one source of truth. See `harness-adapters/pi/README.md` and `docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md`. |

## Preconditions

- **Headless needs `-a` / `--approve`** (e.g. `pi -p -a`). That grants project trust so the tool call reaches the dispatcher's `tool_call` handler; without it pi may resolve the action before the gate sees it. `-a` is the precondition the live proof ran under.
- Loaded from inside an apexyard ops fork, or with the `APEXYARD_OPS_ROOT` override documented in `harness-adapters/pi/README.md` when running outside the fork's working tree.

## What does NOT work yet

| Gap | Why | Tracked as |
|-----|-----|-----------|
| **Role-trigger advisory banners** | Claude Code's `detect-role-trigger.sh` posts a `PreToolUse` reminder banner when a diff matches a role trigger (e.g. touching `**/auth/**`). Pi has no hook to run that check | Self-check `.claude/rules/role-triggers.md` manually |
| **Slash-command UX** for skills | Pi has no command-registration mechanism; skills require reading their `SKILL.md` and following the process by hand | Not tracked: an ergonomics gap, not a governance one |
| **Plan mode, background bash, permission popups** | Deliberately absent from pi's design, not apexyard-specific gaps | N/A: approximate with an explicit "here is my plan, confirming before I execute" pause where `.claude/rules/plan-mode.md` would otherwise apply |
| **Claude Code's session-pin protection against wrong-ops-root resolution** (apexyard#381) | pi has no `CLAUDE_CODE_SESSION_ID` / SessionStart-hook equivalent to write the pin | Use the `APEXYARD_OPS_ROOT` env var override documented in `harness-adapters/pi/README.md` when running pi outside the ops fork's own working tree |

## The honest summary

A pi user gets both halves of apexyard's governance: the **instructions** (via `AGENTS.md`/`SYSTEM.md`, unchanged since #805). As of #815, the user also gets the same **mechanical gates** Claude Code enforces. The real bash hook running underneath pi refuses an ungated action, rather than only discouraging it in prose. As of 2026-07-09 that enforcement is **live-proven**. The "does pi's live internal dispatch call the handler this way" step was this doc's one remaining uncertainty. That step now has observed evidence inside a credentialed `pi -p -a` session, beyond proof by construction. The only thing between an adopter and enforcement is the `-a` precondition above.

## How to install

```bash
bash bin/install-pi-adapter.sh
```

That writes the adapter into `.pi/extensions/apexyard/`: a **subdirectory** shape (confirmed against pi 0.80.3, #844/#845). pi's local-extension discovery scans `.pi/extensions/` and requires every `.ts` file it finds to export a valid default factory. A flat `cp` of the dispatcher plus its helper modules makes pi try to load each helper as an independent extension. This fails the session. The install script produces the one-subdirectory-behind-an-`index.ts`-shim layout mechanically (and rewrites the one shared-core import path). Then run `pi` from the project containing `.pi/extensions/`: it auto-discovers `.pi/extensions/apexyard/index.ts`.

Orientation docs (`AGENTS.md` + `SYSTEM.md`) auto-load from the fork's cwd with no extra step; see `harness-adapters/pi/README.md` for the manual `--extension` form and the `APEXYARD_OPS_ROOT` override.

## omp (oh my pi)

Tests used omp 18.10.2, with the macOS arm64 release binary.
The binary SHA-256 matched the release `SHA256SUMS.txt`:
`9752e3d7f7bdab636e21495a6affc196e8ffc3a2dffaf529db2dd73d2bdea255`.
Tests used print mode (`omp -p`), `--auto-approve`, and a local scripted model server.
Tests did not use a hosted model.
Tests did not cover interactive mode, MCP, the `task` subagent tool, or Linux and Windows binaries.
A later release can change the extension or hook format.
Name the tested version when you report support.

Install the adapter:

```bash
bash bin/install-pi-adapter.sh --target-dir <project>/.omp/extensions
```

omp finds `<project>/.omp/extensions/apexyard/index.ts` automatically.
omp does not scan `.pi/extensions`, so the default Pi install path does not load in omp.
Alternatively, use `omp -e <path>/index.ts`.
omp keeps user data in `~/.omp/agent`.
The `PI_CODING_AGENT_DIR` variable changes this directory.

omp loads the full text of `AGENTS.md` without extra setup.
It lists skills from `.claude/skills/`.
Use the `read` tool with `skill://<name>` to read a skill file.
It loads `.cursor/rules/*.mdc` as generic rules.
It loads one project context file at each directory depth.
`AGENTS.md` takes priority, so `CLAUDE.md` does not load.
The project root `SYSTEM.md` does not load.
omp reads `SYSTEM.md` from config directories such as `.omp/`.
Read `.claude/rules/*.md` on demand, as in Pi.

omp does not run shell hooks from `.claude/settings.json` or `.cursor/hooks.json` without the adapter.
Without the adapter, a control run allowed a push to `main`, a merge without review, and a code write without a ticket.
Only the adapter enforces the gates.
Tests with the adapter produced these hook messages:

| Action | Result |
|--------|--------|
| Push to `main` | Blocked: "Cannot push directly to a protected branch ('main')." |
| Merge with no review, forge reachable | Blocked: "PR #N has no recorded code-reviewer (Rex) approval." |
| Merge, forge not reachable | Blocked (fail-closed): "could not resolve PR #N's HEAD from the forge." |
| `write` or `edit` of a code file with no active ticket | Blocked: "No active ticket set for this session." |
| `edit` that touches `.claude/hooks` or `.claude/settings.json`, including an `MV` line | Blocked: "the edit target is live hook state." |
| `eval` tool | The adapter blocks the tool. Code run by `eval` can do what the bash gates block. Use `bash` for gate checks. |

A local sequence passed these steps:

1. Declare a ticket through the gated `bash` tool to write the marker.
2. Create a branch.
3. Write a file.
4. Edit the file.
5. Run `git add`.
6. Run `git commit`.
7. Push the feature branch to a local remote.

The Rex review did not run.
Like Pi, omp has no subagent spawn that the adapter can use for Rex.
The merge gate required the review marker.

| Topic | Pi | omp |
|-------|----|-----|
| Extension folder | `.pi/extensions/` | `.omp/extensions/`. omp does not scan `.pi/extensions/`. |
| User config folder | `~/.pi/agent` | `~/.omp/agent` |
| `edit` tool input | `path` plus edit pairs | One `input` text has `[PATH#TAG]` headers for one or more files, plus `REM` and `MV DEST` lines. omp also sets `path` (first file) and `paths`. |
| File-hook field | Hooks need `file_path`. The adapter sends `file_path` and `path`. | Hooks need `file_path`. The adapter sends `file_path` and `path`. |
| Search tools | `find`, `grep`, `ls` | `glob`, `grep`. The adapter has no gate input for these tools. No gate uses them today. |
| Code-run tool | see the Pi docs | `eval` runs Python or JavaScript. The adapter blocks it. |
| Native hooks from `.claude/settings.json` | Not run | Not run |
| Event names used by the adapter | `session_start`, `tool_call` | `session_start`, `tool_call` |

This change also fixes file gates for Pi and omp.
Previously, `block-protected-target-writes.sh` blocked every `edit` and `write` call because the adapter sent only `path`.
The adapter now sends both `file_path` and `path`.

## Roadmap

me2resh/apexyard#804 (spike) proved the adapter-over-bash pattern viable. #815 shipped the dispatcher covering the merge gate, red-CI block, design/architecture review, secrets scanning, and ticket-first gates. The 2026-07-09 live run proved it enforces during a real model turn. #845 hardened the install shape. The next steps have no ticket scope yet: porting role-trigger advisory banners and/or a slash-command-equivalent skill runner. These steps depend on pi's extension API growing the right hooks for either.

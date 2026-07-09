# Harness support — Claude Code

**Status:** Native — the reference harness. Full experience, gates enforced live.

Claude Code is the harness ApexYard was built for, and the only one where nothing is adapted: `CLAUDE.md` auto-loads at session start, the bash hooks fire on real tool calls, skills are typed slash commands, and agents spawn with their own tool restrictions. Everything the other harness pages describe as "delegated" or "planned" is simply *native* here.

## What "full experience" concretely means

- **`CLAUDE.md` auto-load** — the Chief-of-Staff framing, SDLC, workflow gates, and the `@.claude/rules/*.md` imports are loaded into every session without any manual step.
- **Mechanical gates fire on every tool call** — the `.claude/hooks/*.sh` scripts wire to `PreToolUse` / `PostToolUse` / `SessionStart` via `.claude/settings.json` and block (exit 2) or advise (exit 0) in real time.
- **Slash-command skills** — each `.claude/skills/<name>/SKILL.md` is a typed `/command` (e.g. `/start-ticket`, `/decide`, `/code-review`, `/approve-merge`).
- **Sub-agents** — Rex (code review), Hakim (security), Tariq (design review), Naqid (the contrarian), plus the department personas, each spawned via the `Agent` tool with role-scoped tools.
- **Session markers + memory** — review approvals live under `.claude/session/reviews/*.approved`; the ops-root session pin (`~/.claude/apexyard/ops-root-<session>`) protects against wrong-fork resolution (apexyard#381); per-project auto-memory persists across sessions.

## What's enforced vs advisory today

**Mechanically enforced (blocking):** the two-marker merge gate (Rex + CEO), red-CI merge block, ticket-first edits, migration-ticket-first edits, design-review gate for UI PRs, architecture-review gate for design-artifact PRs, secrets scanning, private-ref leak protection, branch-name and PR-title validation, and AgDR-for-architecture-change prompts.

**Advisory (non-blocking reminders):** role-trigger banners (`detect-role-trigger.sh`), upstream-drift notices, MCP-reindex-after-clone/-pull nudges, and the self-discipline rules (plan mode, parallel-work/fan-out offers, loop mode, reporting style).

## How it works (transport)

There is no transport layer — Claude Code *is* the runtime the other adapters shell out to. The hooks read tool-call JSON on stdin, decide, and return an exit code Claude Code honors directly. `.claude/` is the canonical authoring surface for every other harness precisely because it is executed natively here.

## How to install

Fork `me2resh/apexyard`, clone it, run `/setup`, and register projects with `/handover`. The `.claude/` directory is picked up automatically. Full walkthrough: [`docs/getting-started.md`](../getting-started.md); portfolio model: [`docs/multi-project.md`](../multi-project.md).

## Preconditions

None beyond a working Claude Code install. The hooks are wired natively via `.claude/settings.json` and fire on every tool call — no adapter, no install flag, and (unlike the delegating adapters) no trust/approval precondition to satisfy first. The single OS-level prerequisite: on Windows the bash hooks need Git Bash / WSL.

## What's verified

Enforcement is native and exercised continuously — every gate in this framework runs against Claude Code itself on every session. This is the reference surface the other adapters are measured against.

## Gaps + tracking

None specific to Claude Code — it is the feature-complete baseline. The one cross-cutting limitation is OS-level: on Windows the hooks require Git Bash / WSL (a documented prerequisite, not a silent failure — see [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md)).

## Related AgDRs

- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash; other OSes/harnesses reach them via adapters
- [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md) — reasoning-layer reviewers keep a frontier-model floor

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

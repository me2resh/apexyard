# Harness support: Claude Code

**Status:** Native: the reference harness. Full experience, gates enforced live.

Claude Code is ApexYard's reference harness. Nothing needs translation. `CLAUDE.md` loads at session start. Bash hooks run on real tool calls. Skills act as typed slash commands. Agents start with their own tool restrictions. Features described as "delegated" or "planned" on other harness pages are native here.

## What "full experience" means

- **`CLAUDE.md` auto-load:** the Chief-of-Staff framing, gates, and rule index load at session start. `/setup` and SessionStart write this clone's absolute rule exclude into gitignored `.claude/settings.local.json`. Agents Read named framework rules when needed. Personal and managed-project rules remain eligible to load unless other settings exclude them. A new or repaired exclude applies in the next session. See AgDR-0233 and AgDR-0160.
- **Mechanical gates fire on every tool call:** the `.claude/hooks/*.sh` scripts wire to `PreToolUse` / `PostToolUse` / `SessionStart` via `.claude/settings.json`. They block (exit 2) or advise (exit 0) in real time.
- **Slash-command skills:** each `.claude/skills/<name>/SKILL.md` acts as a typed `/command` (e.g. `/start-ticket`, `/decide`, `/code-review`, `/approve-merge`).
- **Sub-agents:** Rex (code review), Hakim (security), Tariq (design review), Naqid (the contrarian), plus the department personas. The `Agent` tool spawns each one with role-scoped tools.
- **Session markers + memory:** review approvals live under `.claude/session/reviews/*.approved`. The ops-root session pin (`~/.claude/apexyard/ops-root-<session>`) protects against wrong-fork resolution (apexyard#381). Per-project auto-memory persists across sessions.

## Enforcement vs advisory today

**Mechanically enforced (blocking):** the two-marker merge gate (Rex + CEO), red-CI merge block, ticket-first edits, and migration-ticket-first edits. The design-review gate for UI PRs and the architecture-review gate for design-artifact PRs also apply. Secrets scanning, private-ref leak protection, branch-name and PR-title validation, and AgDR-for-architecture-change prompts also apply.

**Advisory (non-blocking reminders):** role-trigger banners (`detect-role-trigger.sh`), upstream-drift notices, and the self-discipline rules (plan mode, parallel-work/fan-out offers, loop mode, reporting style).

## How it works (transport)

There is no transport layer for Claude Code itself. Cursor can load the same `.claude/` files when third-party configs are on. See [cursor.md](cursor.md). The hooks read tool-call JSON on stdin, decide, and return an exit code the harness honors. `.claude/` is the canonical authoring surface for every other harness because Claude Code executes it natively.

## How to install

Fork `me2resh/apexyard`, clone it, run `/setup`, and register projects with `/handover`. The harness picks up the `.claude/` directory automatically. Full walkthrough: [`docs/getting-started.md`](../getting-started.md); portfolio model: [`docs/multi-project.md`](../multi-project.md).

## Preconditions

None beyond a working Claude Code install. `.claude/settings.json` wires the hooks natively. They fire on every tool call. There is no adapter, no install flag, and (unlike the delegating adapters) no trust/approval precondition to satisfy first. The single OS-level prerequisite: on Windows the bash hooks need Git Bash / WSL.

## What live use verifies

Enforcement is native and in continuous use. Every gate in this framework runs against Claude Code itself on every session. The other adapters use this reference surface as their baseline.

## Gaps + tracking

None specific to Claude Code. It is the feature-complete baseline. The one cross-cutting limitation is OS-level. On Windows the hooks require Git Bash / WSL. That is a documented prerequisite, not a silent failure. See [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md).

## Related AgDRs

- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md): hooks stay bash; other OSes/harnesses reach them via adapters
- [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md): reasoning-layer reviewers keep a frontier-model floor

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

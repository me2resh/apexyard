# Revive the deprecated `/onboard` as the guided first-run orchestrator

> In the context of needing a first-run surface for the guided-onboarding walking skeleton (increment 1, PRD #902/#905), facing a choice between adding a new skill, bloating `/setup`, or reclaiming the deprecated `/onboard` alias, I decided to repurpose `/onboard` as a thin orchestrator + router over the unchanged `/setup` / `/handover` / `/feature` skills to achieve a single intuitive front door with zero net new skill surface, accepting that reviving a deprecated alias needs a clear migration note and rewrites of the `/onboard` SKILL and the CLAUDE.md skill table.

## Context

Increment 1 of the guided first-run onboarding initiative (technical design: `docs/technical-designs/onboarding-increment-1.md`, ticket #909) needs a **first-run surface** — the skill an adopter runs (or is nudged toward by the `onboarding-check.sh` SessionStart banner) on a genuinely fresh fork. It must:

- Present a capability tour, then an explicit *handover-vs-new-project* branch, then a guided first win.
- **Reuse `/setup` (config), `/handover` (repo adoption), and `/feature` (ticket creation) unchanged** — the PRD Non-Goal forbids re-architecting them, and the Backward-compatibility NFR requires their direct/scripted behaviour stay byte-for-byte identical.

FR-1 explicitly allows either "a new skill" or "an extension of `/setup`'s Step 1 detection". `/onboard` currently exists only as a **deprecated redirect** ("use `/setup` or `/handover`"), left behind when the original `/onboard` was split for conflating framework-bootstrap with per-project discovery.

This is a framework-surface-altering decision (it changes what a top-level skill *is*), so it is AgDR-class per Gate 2. Recorded at the request of the Gate-3b design review (Tariq).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Net-new `/first-run` skill**, leave `/onboard` deprecated | Clean separation; `/setup` untouched | Two adjacent names — a live `/first-run` **and** a dead `/onboard` — is confusing; net **+1** top-level skill while a deprecated redirect lingers indefinitely |
| **B. Extend `/setup` inline** (fold tour + branch + first win into `/setup`) | One front door adopters already know; most literal reading of "reuse detection" | Risks the Backward-compat NFR (scripted `/setup --all` must stay byte-for-byte); `/setup` is already ~666 lines and would bloat further; couples config-bootstrap to the experience-wrapper |
| **C. Revive deprecated `/onboard`** as a thin orchestrator + router over unchanged `/setup` / `/handover` / `/feature` *(chosen)* | Zero net new skill count (reclaims a dead name); `/onboard` is *already* the conceptual router (setup-vs-handover); the name a newcomer intuitively types; the original deprecation reason is **resolved** — the new `/onboard` doesn't conflate concerns, it routes to the two purpose-specific skills | Reviving a deprecated alias needs a visible migration note; the `/onboard` SKILL and the CLAUDE.md skill table must be rewritten |

## Decision

Chosen: **Option C — repurpose `/onboard`**, because it delivers a single intuitive first-run front door with **zero net new skill surface** while keeping `/setup` and `/handover` untouched. The key insight: the original deprecation rationale was that `/onboard` *conflated* framework-bootstrap with per-project discovery. The revived `/onboard` does the opposite — it is a thin experience-wrapper and router that sequences the two purpose-specific skills behind a tour and a branch, so the very reason it was deprecated no longer applies. `/setup` remains directly runnable for adopters who want only the config bootstrap; the `onboarding-check.sh` banner changes from "Run `/setup`" to "Run `/onboard`".

Downstream design (detection library D2, shared tour asset D3, `/tutorial` D4, the resolved open questions D5/D6, and the #910/#911 task breakdown) is **name-agnostic** — if a future reviewer prefers Option A's `/first-run`, only the skill's name changes, not the architecture.

## Consequences

- The `.claude/skills/onboard/SKILL.md` deprecated redirect is **rewritten** into the live orchestrator (build task in #910).
- `onboarding-check.sh`'s SessionStart banner is updated to recommend `/onboard`; `/setup` stays directly runnable and unchanged.
- `/onboard` is added to `ticket.bootstrap_skills` (it runs before a portfolio exists) and writes/clears its own `.claude/session/active-bootstrap` marker, mirroring `/setup`.
- The CLAUDE.md skill table + the `/onboard` one-line summary are updated to reflect the live behaviour.
- Backward compatibility holds **structurally**: `/onboard` invokes `/setup`/`/handover`/`/feature`, never edits them, so their direct and scripted (`--all`) behaviour is byte-for-byte preserved.

## Artifacts

- Technical design: `docs/technical-designs/onboarding-increment-1.md` § "D1"
- PRD: `docs/prds/onboarding-overhaul.md` (#902 / #905)
- Ticket: [me2resh/apexyard#909](https://github.com/me2resh/apexyard/issues/909) · PR [#917](https://github.com/me2resh/apexyard/pull/917)
- Build tickets: [#910](https://github.com/me2resh/apexyard/issues/910) (first-run flow), [#911](https://github.com/me2resh/apexyard/issues/911) (`/tutorial`)
- Related: AgDR-0098 (`_lib-fresh-fork.sh` shared detector)

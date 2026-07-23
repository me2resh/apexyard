---
id: AgDR-0105
timestamp: 2026-07-22T06:00:00Z
agent: claude (Tech Lead — Hisham)
model: claude-opus-4-8[1m]
trigger: user-prompt
status: executed
---

# Retire the two lifecycle agents superseded by skills + gates

> In the context of apexyard's sub-agent roster having grown two pre-abstraction "lifecycle" agents — `pr-manager` and `ticket-manager` — whose instructions today either misfire or are mechanically blocked, facing evidence that following the PR agent literally produces an *unapproved merge* and that the ticket agent's core action is already gated shut, I decided to **retire both agents** (delete the files, hand both lifecycles fully to the structured skills that now own them) rather than rewrite them in place or rename the colliding persona, to achieve a smaller, safer, better-routing roster, accepting that any future need for these behaviours is served by the skills — and rollback is a one-command `git revert`.

## Context

- **`pr-manager` is dangerous as written.** Its documented flow is thumbs-up-then-merge-promptly via a **raw CLI merge**. Following it literally bypasses the structured CEO approval marker, the `/approve-merge` skill, and the forge-aware merge wrapper — i.e. it produces an **unapproved merge**, exactly the failure the merge gate exists to prevent (`.claude/rules/pr-workflow.md` § "Plan-level 'go' is NOT merge approval").
- **`pr-manager`'s persona collides.** Its persona name is "Tariq" — the same persona already owned by the Solution Architect. That breaks the unique-persona convention established in [AgDR-0018](AgDR-0018-persona-naming-convention.md).
- **`ticket-manager` is already gated shut.** Its core instruction is raw-CLI issue creation (`gh issue create`), which `require-skill-for-issue-create.sh` (#268) mechanically blocks unless a structured skill (`/task`, `/feature`, `/bug`, `/spike`, `/migration`, `/investigation`, `/idea`) is in flight. The agent can no longer perform its defining action.
- **The lifecycles already have owners.** PR lifecycle → `/approve-merge` + the merge-gate hooks + the forge-aware wrapper. Ticket lifecycle → the structured ticket skills above. Both agents describe pre-abstraction mechanics that predate those owners.
- Community evidence on agent routing favours smaller rosters: fewer near-duplicate agents route more reliably.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Rewrite both in place | Keeps the roster entries; no count churn | Duplicates content the structured skills already own; keeps two routing targets that overlap the skills — the ambiguity that made them misfire persists |
| Rename `pr-manager`'s persona only | Cheap; fixes the AgDR-0018 collision | Fixes only the name — leaves the dangerous raw-CLI merge mechanics and the already-gated ticket agent untouched |
| **Retire both (delete)** — **chosen** | Removes the dangerous flow, the persona collision, and a dead (gated) agent in one move; hands both lifecycles cleanly to their skill owners; smaller roster routes better | Loses the roster entries (recoverable); requires a coordinated count/roster doc sweep |

## Decision

Chosen: **retire both agents** — `git rm .claude/agents/pr-manager.md` and `.claude/agents/ticket-manager.md`. The structured skills and merge-gate hooks own both lifecycles; the agents added only overlap and, in `pr-manager`'s case, an actively unsafe instruction. Persona and routing ambiguity are removed rather than patched.

Rollback is a plain `git revert` of the retirement commit — the files return verbatim and the counts revert with them.

## Consequences

- Tracked sub-agent count drops **25 → 23**; the utility sub-count drops **6 → 4**. Updated in `CLAUDE.md`, `docs/whats-inside.md` (count lines + "The 23 sub-agents" heading + roster line), and `README.md`.
- No agent now instructs a raw-CLI merge; the only sanctioned merge path is `/approve-merge` (per-PR CEO marker) through the forge-aware wrapper.
- The persona namespace is clean again — "Tariq" belongs solely to the Solution Architect, honouring AgDR-0018.
- Out-of-manifest references to the two agents in `AGENTS.md`, `docs/local-model-setup.md`, `docs/spikes/claude-model-tier-routing.md`, `docs/architecture/apexyard-container.md`, and `docs/agdr/AgDR-0018-persona-naming-convention.md` remain and are handed to the parallel-agent sweep (AgDR-0018 is a historical record and should keep its reference).

## Artifacts

- Issue: [me2resh/apexyard#983](https://github.com/me2resh/apexyard/issues/983)
- Branch: `chore/GH-983-retire-lifecycle-agents`

---
status: accepted
date: 2026-05-17
deciders: framework maintainer
related: me2resh/apexyard#268, AgDR-0011-bootstrap-skill-exemption.md
---

# AgDR-0030 — Skill-gated ticket-create (multi-tracker)

> In the context of agents silently bypassing the structured ticket skills (`/task`, `/feature`, `/bug`, `/spike`, `/migration`, `/investigation`, `/idea`) by calling raw `gh issue create` (and parallel CLIs on Linear / Jira / Asana / etc.), facing the risk that ad-hoc tickets ship without the interview the skill's contract enforces (driver/scope/AC, user story/AC, Given/When/Then, hypothesis/budget/kill-criteria, etc.), I decided to add a `PreToolUse:Bash` hook that blocks raw ticket-create CLIs unless a skill-marker is in flight, with the matcher list config-driven so adopters extend it for non-GitHub trackers without code changes, to achieve "every ticket conforms to its skill's contract by construction", accepting the cost of one extra hook in the chain plus the operator-managed marker lifecycle inside the seven ticket skills.

## Context

`validate-issue-structure.sh` (#192) catches *missing prefix / missing sections* in already-drafted ticket bodies. It does **not** catch the upstream failure: the agent skipped the structured-skill interview entirely and drafted a body free-hand. me2resh/apexyard#265 and #266 were both filed via raw `gh issue create` because the interactive skills "felt heavy for context the operator had already provided" — exactly the silent-bypass-for-throughput failure mode the **"Invoke matching skills"** operator-feedback memory was meant to prevent.

The framework is also multi-tracker by design. Per `docs/multi-project.md` § FAQ ("Can I use this with Linear / Jira / etc.?"), adopters set per-project `ticket_prefix` and may use Linear, Jira, Asana, or another tracker. The gate must not bake `gh`/GitHub in as the only CLI shape.

The bootstrap-skill exemption (AgDR-0011) already establishes the marker-file pattern for "this skill is in flight, exempt me from a gate" — `.claude/session/active-bootstrap` + `clear-bootstrap-marker.sh` SessionStart cleaner + config-driven `ticket.bootstrap_skills` list. Mirroring that pattern keeps the framework internally consistent.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Skill-marker + config-driven matcher list** (chosen) | Mirrors existing bootstrap-exemption pattern; tracker-agnostic by construction; adopters extend matcher list without touching framework code; env-var escape hatch for recovery scenarios | Adds a hook to the chain; each ticket skill must manage the marker (write on entry, clean on exit); stale markers possible if a skill crashes (mitigated by SessionStart cleaner) |
| Bake `gh issue create` in as the only matched shape | Simplest possible hook | Useless for Linear/Jira/Asana adopters; bakes GitHub assumption into a framework that explicitly supports multi-tracker |
| Block at PR/commit time (downstream) instead of at create time | One less hook | Tickets are already filed; reverting requires gh issue close + recreate; the agent's bypass already happened |
| Require an `--allow-raw` flag on the CLI | No env var to remember | Unknown flag is rejected by gh/linear/jira/asana — would need a wrapper, which itself requires adoption discipline |
| Permanent config-block bypass (`ticket.allow_raw: true`) | Easy to flip per adopter | Wrong shape — the bypass should be per-session (rare), not per-adopter (always-on) |

## Decision

Chosen: **skill-marker + config-driven matcher list**, because it (a) mirrors the existing bootstrap-skill exemption (AgDR-0011) so the framework stays internally consistent; (b) is tracker-agnostic by construction — only the matcher list knows about specific CLIs and adopters extend it via shallow-merge in `.claude/project-config.json`; and (c) supports the recovery scenario through a per-session env-var escape hatch (`APEXYARD_ALLOW_RAW_TICKET_CREATE=1`) with a visible stderr warning.

Concretely:

1. New hook `.claude/hooks/require-skill-for-issue-create.sh` (PreToolUse:Bash). Reads `ticket.create_command_patterns` from project config; substring-matches the (whitespace-collapsed) bash command. On match:
   - If bootstrap marker present AND active bootstrap skill is on `ticket.bootstrap_skills` → allow (e.g. `/handover` filing its bookkeeping issues).
   - Else if `.claude/session/active-issue-skill` present → allow (one of the seven ticket skills is in flight).
   - Else if `APEXYARD_ALLOW_RAW_TICKET_CREATE=1` → allow with stderr warning.
   - Else → BLOCK with exit 2 and a clear message naming the seven skill alternatives + the env-var bypass.

2. New SessionStart hook `.claude/hooks/clear-issue-skill-marker.sh` (mirror of `clear-bootstrap-marker.sh`) sweeps stale markers from killed sessions.

3. New config key `ticket.create_command_patterns` in `project-config.defaults.json` with default patterns covering GitHub CLI (`gh issue create`, `gh api repos/`), Linear (`linear issue create`), Jira (`jira issue create`, `jira create`), Asana (`asana task create`). Adopters extend via shallow-merge.

4. The seven ticket skills (`/task`, `/feature`, `/bug`, `/spike`, `/migration`, `/investigation`, `/idea`) each write `.claude/session/active-issue-skill` on entry and remove it on completion / cancel.

## Consequences

- Every new ticket from a Claude Code session is filed through a structured skill that runs the contract-shaped interview, OR through an explicitly-acknowledged env-var bypass. No more silent ad-hoc filings.
- Adopters on Linear / Jira / Asana / custom trackers extend the matcher list in `.claude/project-config.json` without touching framework code.
- Marker lifecycle is operator-managed inside the seven ticket skills — if a skill is updated to add new exit paths, the marker-cleanup step must be added to each. The SessionStart cleaner is the safety net for the crash-mid-skill failure mode.
- Bootstrap-skill exemption continues to work — `/handover` filing tickets for newly-adopted projects is unaffected because the bootstrap marker takes precedence.
- `validate-issue-structure.sh` continues to compose downstream: it validates body structure; this hook validates origin. Both fire on `gh issue create`.
- Multi-tracker scope deliberately leaves `validate-issue-structure.sh` GitHub-specific for now (it parses `gh` flags). Broadening that hook is a separate follow-up.

## Artifacts

- Issue: [me2resh/apexyard#268](https://github.com/me2resh/apexyard/issues/268)
- PR: `feat(#268): skill-gated ticket-create hook (multi-tracker)` against `dev`
- New hook: `.claude/hooks/require-skill-for-issue-create.sh`
- New SessionStart hook: `.claude/hooks/clear-issue-skill-marker.sh`
- Config: `.claude/project-config.defaults.json` → `ticket.create_command_patterns`
- Tests: `.claude/hooks/tests/test_require_skill_for_issue_create.sh`
- Related: AgDR-0011 (bootstrap-skill exemption — the pattern this mirrors)

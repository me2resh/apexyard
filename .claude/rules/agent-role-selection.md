# Agent Role Selection — Spawn the Role-Appropriate Sub-Agent

[`role-triggers.md`](role-triggers.md) governs role activation for **in-thread edits** — a diff touching `**/auth/**` fires the Security Auditor, a diff under `.github/workflows/**` fires the Platform Engineer, and so on. That coverage stops at the edit boundary. It says nothing about the **other** place a role gets chosen: the moment an orchestrator calls the `Agent` tool and picks `subagent_type` for a fan-out task, a `/fan-out` item, or a `Workflow` stage.

This is a real gap, not a hypothetical one. Handing build/coding/design work to `general-purpose` (or the catch-all `claude`) instead of the role-appropriate sub-agent silently discards everything that agent wrapper carries: the role's identity, its CAN/CANNOT boundaries, its tool restrictions, and its SDLC handoff semantics (see [`pr-workflow.md`](pr-workflow.md) § "Build agents cannot self-review" for one concrete consequence of losing that identity). A `general-purpose` agent building an API endpoint can still produce working code — but it isn't bound by `backend-engineer`'s clean-architecture CANNOTs, isn't primed with the domain-layer conventions, and reports back without the role framing a human reviewer expects.

## The mapping

When spawning substantive build/coding/design work via the `Agent` tool, pick `subagent_type` from the work, the same way `role-triggers.md` picks a role from a diff:

| Work is about… | `subagent_type` |
|-----------------|------------------|
| Backend / domain / application logic, APIs, database schema | `backend-engineer` |
| UI components, design-system integration, accessibility | `frontend-engineer` |
| CI/CD pipelines, hooks, IaC, developer tooling, golden-path templates | `platform-engineer` |
| Technical design docs, architecture review, task breakdown | `tech-lead` (author) / `solution-architect` (independent reviewer) |
| PRDs, user stories, acceptance criteria | `product-manager` |
| ETL, data modelling, warehouse schema, data quality | `data-engineer` |
| Visual design, component specs, design tokens | `ui-designer` |
| User flows, information architecture, usability | `ux-designer` |
| Code review of a diff | `code-reviewer` |
| Security / OWASP / SAST review | `security-reviewer` |
| Genuine research or code search with no role home — "where is X defined", "how do libraries A/B/C compare" | `general-purpose` or `Explore` |

The last row is the escape valve, not the default. `general-purpose` is for work that doesn't decompose into a role at all — open-ended investigation, multi-location search, a question with no single owning discipline. It is not a shortcut for "I don't want to look up which role fits."

## When to apply this (proactively)

Heuristic: before every `Agent` tool call, and before every `/fan-out` task list, check whether the task is substantive build/coding/design work with a role home in the table above. If yes, use that `subagent_type`. This applies whether the call is a single spawn, a `/fan-out` batch, or a `Workflow` fleet stage — the mapping is the same regardless of which primitive does the spawning.

## When NOT to bother

- **Genuine research/search with no role home** — a cross-repo grep, "how does library X handle pagination", open-ended discovery. `general-purpose` / `Explore` is correct here, not a compromise.
- **Utility agents that aren't department roles** — `code-reviewer` (Rex), `security-reviewer` (Hakim), `solution-architect` (Tariq), `contrarian` (Naqid) are already the right pick for their specific jobs; this rule doesn't ask you to route around them.
- **A task genuinely spans multiple roles inseparably** — if a single spawn would need to be both `backend-engineer` and `frontend-engineer` at once, that's a sign the task should be split into per-role spawns (see [`parallel-work.md`](parallel-work.md)), not a reason to fall back to `general-purpose`.

## Self-check before spawning

Before emitting an `Agent` tool call (or a `/fan-out` task list), scan the task for:

```
[ ] Does this task's work fall into a row of the mapping table above?
[ ] If yes, does my subagent_type match that row — not general-purpose/claude by default?
[ ] If I picked general-purpose/Explore, is this genuinely research/search with no role home?
[ ] For a multi-task fan-out, did I pick a subagent_type per task, not one generic type for all?
```

If the first box is checked and the second isn't, fix `subagent_type` before spawning — not after the sub-agent reports back with role-less output.

## Backstop

This rule is **primarily self-discipline** — the same shape as [`parallel-work.md`](parallel-work.md) and [`plan-mode.md`](plan-mode.md). Mechanical enforcement at the spawn boundary is not currently shipped: unlike `Edit`/`Write`/`Bash`, the `Agent`/`Task` tool call has no existing `PreToolUse` matcher anywhere in this framework's 40+ hooks, and [AgDR-0056](../../docs/agdr/AgDR-0056-subagent-mcp-first.md) already documents a closely related finding — the current hook plumbing cannot reliably see into a sub-agent boundary. An advisory guard was evaluated for this rule and deferred rather than shipped speculatively; see the tracking issue for the spawn-payload investigation before attempting one.

The cost of checking the mapping table before a spawn is one glance. The cost of a `general-purpose` agent quietly shipping backend code with none of `backend-engineer`'s constraints is a PR that reads like nobody was driving — caught late, usually by a human reviewer noticing the report doesn't sound like the role it should have been.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

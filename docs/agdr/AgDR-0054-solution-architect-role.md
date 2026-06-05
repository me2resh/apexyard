# Add a Solution Architect review role (one role, review-only, gated before Build)

> In the context of the framework having no independent reviewer of solution/technical designs — the Tech Lead authors designs but nobody reviews them before Build — facing the CEO's request for "an architect that reviews the proposed plan/architecture… think Rex for the non-code stuff", I decided to add ONE new role, the **Solution Architect (persona Tariq)**, as a read-only review agent that reviews every technical design / migration AgDR / feature spec at the Design→Build boundary and gates the merge of the design artifact until sign-off, to achieve an independent design-quality check without duplicating the Head of Engineering, accepting a new gate on the design-artifact merge path and a sixth department in the role hierarchy.

## Context

ApexYard already separates authoring from review for **code**: engineers write code, the Code Reviewer agent (Rex) reviews it, and a merge gate enforces the sign-off. There was no equivalent for **designs**. The Tech Lead (Hisham) *authors* technical designs + AgDRs (`roles/engineering/tech-lead.md` § "Technical Design Process"), and the Head of Engineering (Khalid) escalates on enterprise/strategic/cross-project/new-tech-stack architecture — but nothing independently reviewed a routine technical design before the team built against it. Design-level defects (missing NFRs, wrong patterns, untracked decisions, risky migrations) surfaced only at code review or later, when they're far more expensive to fix.

The CEO asked for "a dedicated architect role/agent with proper triggers; the tech lead provides the proposed plan/architecture and they review for feedback — think Rex for the non-code stuff."

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Enterprise Architect + Solution Architect (two roles)** | Mirrors a large-org architecture function | EA remit (enterprise/strategic/cross-project/new-tech) overlaps the existing Head of Engineering almost entirely — duplication, ambiguity over who owns what |
| **One Solution Architect, review-only (chosen)** | Fills the exact gap (independent design review) with no overlap; clean author/reviewer split; mirrors the proven Rex pattern | Adds a role + a gate; design artifacts now need a sign-off before merge |
| **An authoring Solution Architect (PRD → architecture spec)** | One tool produces the design | No independent check — the author reviewing their own work is the gap we're closing; also duplicates the Tech Lead's authoring job |
| **Advisory-only review (no gate)** | Lighter touch | Self-discipline alone; the design-review step gets skipped under time pressure, same failure mode the UI design-review gate was built to prevent |

## Decision

Chosen: **one review-only Solution Architect (Tariq), gated before Build.**

1. **One role, not two.** The Enterprise Architect remit overlaps the Head of Engineering; adding it would duplicate Khalid. Enterprise/strategic/cross-project/new-tech-stack architecture stays with the Head of Engineering. The new role owns *solution/technical design review* only.

2. **Review-only, never authoring.** The Tech Lead authors the design; Tariq reviews it. The agent ships with `disallowedTools: Write, Edit` — it mechanically cannot edit the design. An author reviewing their own design is the gap this closes. (A separate "authoring assist" for the Tech Lead was explicitly considered and declined for this change — kept out of scope to preserve the clean split.)

3. **Gated before Build (Gate 3b).** In the ApexYard SDLC a technical design lands as a committed document (design doc / migration AgDR / PRD) that merges *before* implementation. Gating that merge on Tariq's sign-off is the faithful, mechanical realisation of "review the design before Build". The gate is the non-code analog of `require-design-review-for-ui.sh`: `require-architecture-review.sh` blocks merging a design-artifact PR until `<pr>-architecture.approved` exists at a matching HEAD SHA. The marker is written by Tariq on an APPROVED verdict, or by an operator via `/approve-architecture`.

4. **Modeled on Rex.** Same agent skeleton as the Code Reviewer: `model: opus`, read-only tools (`Read, Grep, Glob, Bash` + MCP search + web), HARD STOP requiring a `gh pr review` before returning, and the same handbook-discovery (public `handbooks/**` + private `custom-handbooks/**`, framework defaults unless overridden in the sibling portfolio repo). Isolated-work-class per AgDR-0050 § Axis 6 — spawned as a sub-agent, like Rex / Hakim / the Tech Lead.

5. **Structured review lens.** Tariq reviews every design against a fixed competency set — quality attributes / NFRs, design patterns, technical debt, decision (AgDR) linkage, risk, trade-off analysis, requirements traceability, and migration safety. AgDR linkage is a blocking check (a real decision with no AgDR → CHANGES REQUESTED), consistent with Rex.

## Consequences

- New `roles/architecture/` department (6th) + `roles/architecture/solution-architect.md`; `.claude/agents/solution-architect.md` review agent.
- New skills: `/design-review` (invoke Tariq) and `/approve-architecture` (record the marker).
- New gate hook `require-architecture-review.sh` wired into both merge shapes (`gh pr merge` + `gh api .../merge`) in `.claude/settings.json`; tests at `.claude/hooks/tests/test_require_architecture_review.sh`.
- `detect-role-trigger.sh` fires Tariq on design-artifact edits (additive to the Tech Lead `docs/agdr/**` trigger — a migration AgDR fires both); `role-triggers.md`, `workflow-gates.md` (Gate 3b), and `workflows/sdlc.md` (Phase 2) updated.
- Framework counts: roles 19→20, agents 23→24, hooks 24→25 (36→37 committed shell scripts), skills 55→57. `CLAUDE.md` + `site/*` refreshed; `test_site_counts.sh` green.
- A design-artifact PR now needs three markers to merge when it's also a code PR: Rex (`-rex`), architecture (`-architecture`), CEO (`-ceo`) — plus design (`-design`) if it touches UI.
- Default design-artifact patterns are configurable (`design_paths` to replace, `design_paths_exclude` to carve out) so adopters whose design docs live elsewhere aren't forced into the default convention.

## Artifacts

- Issue: me2resh/apexyard#471
- New: `roles/architecture/solution-architect.md`, `.claude/agents/solution-architect.md`, `.claude/skills/design-review/SKILL.md`, `.claude/skills/approve-architecture/SKILL.md`, `.claude/hooks/require-architecture-review.sh`, `.claude/hooks/tests/test_require_architecture_review.sh`
- Edited: `.claude/rules/role-triggers.md`, `.claude/hooks/detect-role-trigger.sh` (+ test), `.claude/rules/workflow-gates.md`, `workflows/sdlc.md`, `.claude/settings.json`, `CLAUDE.md`, `site/*`
- Related: AgDR-0050 (agent runtime / Axis 6 isolated-vs-in-flow class), AgDR-0018 (persona naming), the Rex pattern (`.claude/agents/code-reviewer.md`), and the UI design-review gate (`require-design-review-for-ui.sh` + `/approve-design`).

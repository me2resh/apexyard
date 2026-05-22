# AgDR-0051 — `/plan-initiative` — initiative → milestones → tasks with dependency-aware sequencing

> In the context of ApexYard's existing planning skills starting at the ticket level (`/feature`, `/task`, `/bug`, `/spike`) — one unit of work each — with the closest "zoom out" surfaces being `/write-spec` (PRD for one feature) or `/validate-idea` (5-question pre-spec gate), facing the operator-stated need to decompose strategic-shape **initiatives** ("build X capability over the next quarter") into a sequenced, dependency-aware milestone plan without losing the dependency graph or rotting the moment a milestone slips, I decided to ship a new `/plan-initiative` skill that (a) interviews the operator at initiative level for goal / quarter / success criterion / scope, (b) walks them through naming milestones one at a time with a Socratic uncertainty-surfacing question bank (success criterion, blocks, blocked-by, kill criterion, value/risk), (c) computes a recommended sequence via topological sort over the resulting DAG with ties broken by operator-stated value × risk-inverse, (d) writes a structured initiative doc at `projects/<name>/initiatives/<slug>.md` (per-project) or `projects/initiatives/<slug>.md` (framework-wide), (e) optionally files each milestone as a Feature-shape ticket with `blocks` / `blocked by` cross-references via a two-pass dispatch that mirrors the `/handover` step-7.5 per-item filing UX from #376, and (f) is idempotent on re-runs — preserves prior `Filed as #N` markers and prompts only on the deltas — to achieve quarter-shape planning that decomposes deterministically into the existing ticket primitives, accepting the maintenance cost of one new SKILL.md + one new template + one new agdr + the routing-table update for the per-skill activation pattern.
>
> **Status**: ACCEPTED — implementation lives in #377. This AgDR is the design record referenced by that PR.

**Metadata** — Status: ACCEPTED · Category: process · Supersedes: none · Related: [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md) (template-override semantics the new template plugs into), the `/handover` step-7.5 filing pattern (`.claude/skills/handover/SKILL.md` § 7.5 — the UX mirror) ; tracked by GitHub Issue [#376](https://github.com/me2resh/apexyard/issues/376) (the handover sibling that established the per-item filing UX). (Body-H1 only, no YAML frontmatter — per the live convention since markdownlint MD025 trips on YAML title + body H1 simultaneously.)

## Context

ApexYard's planning surface today bottoms out at the **ticket primitive**: one feature, one bug, one task, one spike. The closest things to "zoom-out" are `/write-spec` (PRD for ONE feature) and `/validate-idea` (5-question pre-spec gate for ONE idea). Operators who want to plan at the **initiative level** — the strategic unit above features, usually 1-3 per quarter, multi-feature, multi-week — end up doing it in prose: a markdown file at `notes/q3-initiative.md` with bullet-point milestones, no DAG, no tracker links, no idempotence on re-runs.

The failure modes that prose-in-a-notes-file produces are predictable:

1. **Dependency graph rot.** "Milestone 3 must come after milestone 1" is captured as prose. The operator reorders the list, forgets the dependency, files milestone 3's tickets first, discovers mid-sprint that the work is blocked.
2. **Drift between plan and tracker.** Milestones get filed as ad-hoc `/feature` tickets; the original plan doc never gets updated; six weeks later the plan says "Milestone 2 in progress" while the tracker says "Milestone 2 done, Milestone 3 in progress".
3. **No uncertainty surfacing.** Operators commit to milestones without articulating kill criteria, value, or risk. When a milestone slips, there's no recorded "we would cancel this if X" — so the team grinds through low-value work instead of cutting it.
4. **Reinventing decomposition each time.** Every new initiative starts with "what's a good way to break this into milestones again?" — the framework offers no shape for the operator to fill in.

`/plan-initiative` is the orchestrator surface above `/write-spec` and `/feature` — quarter-shape planning that decomposes into the ticket primitives the framework already governs:

```
/idea            (capture a raw idea)
/validate-idea   (5-question pre-spec gate)
/plan-initiative (NEW — initiative → milestones → tasks, dependency-aware)
/write-spec      (PRD for one feature)
/feature / /task / /bug / /spike (one ticket at a time)
```

After the interview, each milestone naturally becomes a `/write-spec` invocation, which decomposes into multiple `/feature` invocations. The skill does not replace those — it sits above them.

## Options Considered

Four load-bearing decisions are presented as one option-matrix each. Implementation flows from the "Decision" section below.

### Axis 1 — Decomposition shape: Socratic interview vs LLM auto-decompose vs hybrid

| Option | Pros | Cons |
|--------|------|------|
| **LLM auto-decompose** (skill takes the initiative goal, emits N milestones with dependencies inferred) | Fast — operator types one sentence, gets a plan | Plan is a black box. Operator hasn't articulated kill criteria, value, or dependencies; the LLM has guessed at them. The plan that lands in the doc is the LLM's plan, not the operator's. Most damaging: it removes the **forcing function** that makes the operator commit to "Milestone 2 unblocks Milestones 3 + 5" — without that articulation, the dependency graph is fiction. |
| **Socratic interview** (skill asks the operator one milestone at a time, with mandatory questions on success criterion + blocks + blocked-by, plus optional Socratic questions on kill criterion + value + risk that the operator can defer with "TBD") | Forces articulation. The plan that lands in the doc IS the operator's plan, captured in their words. Uncertainty stays visible (as "TBD" markers in the recorded answers) rather than getting smoothed over by an LLM. | Slower per-initiative — a 5-milestone initiative is ~20-30 questions across the whole interview. The cost is the point: planning that takes 5 minutes of typing is more durable than planning that takes 30 seconds of LLM inference. |
| **Hybrid** (LLM proposes the milestone list, operator edits + answers Socratic Qs on each) | Compromise — fastest of the three on initiatives with predictable shapes (e.g. "auth rewrite") | The LLM's initial list anchors the operator. Operators routinely accept a flawed first list rather than restart, even when prompted to edit. Compromise inherits the "plan is the LLM's plan" failure mode just less severely. |

### Axis 2 — Template shape: separate `initiative.md` + `milestone.md` vs single `initiative.md` with inline milestone blocks vs extend `templates/prd.md`

| Option | Pros | Cons |
|--------|------|------|
| **Single `templates/initiative.md` with inline milestone blocks** | One file, one shape. Milestones live as `### Milestone N — Name` headers inside the master doc. The dependency DAG (Mermaid `flowchart LR`) renders once at the top of the file. Re-runs read the one doc, partition milestones into already-filed + new, and update in-place. | Less reusability — a future `/show-milestone` skill (none planned) couldn't open a standalone milestone artefact. v1 acceptable: milestones don't live as standalone artefacts; they exist inside an initiative. |
| **Separate `templates/initiative.md` + `templates/milestone.md`** | Each milestone is reusable / movable across initiatives | The cost is higher than the gain. Milestones don't get moved across initiatives in practice — when an initiative pivots, the milestones get rewritten, not relocated. The second template adds maintenance burden + adopter override surface (per AgDR-0023) for negligible benefit. |
| **Extend `templates/prd.md`** | Reuses an existing template | PRDs are feature-shape (one feature, full spec); initiatives are quarter-shape (multi-milestone, DAG, multi-feature). Forcing the PRD template to flex to both shapes produces a worse PRD AND a worse initiative doc. |

### Axis 3 — Filing UX: single-pass dispatch to `/feature` per accepted milestone vs two-pass with cross-ref rewrite vs single batch via `/tickets-batch`

| Option | Pros | Cons |
|--------|------|------|
| **Two-pass dispatch to `/feature`** (pass 1: file each accepted milestone, capturing the returned issue numbers; pass 2: edit each filed ticket's body to add `blocks: #N` / `blocked by: #N` lines based on the DAG + the now-known issue numbers) | Cross-refs land correctly. Each filed ticket reflects the true dependency graph from the moment it exists in the tracker. | More moving parts — N+M `gh` calls (N filings + M cross-ref edits, where M is the count of milestones that have inbound or outbound DAG edges). For a 5-milestone initiative with a typical DAG, that's roughly 9 calls instead of 5. |
| **Single-pass dispatch with placeholders** (file in DAG topo-order; when filing milestone N, reference earlier milestones' real numbers; rely on topo-order to guarantee blocking-tickets are already filed by the time blocked tickets get filed) | Fewer calls. Cleaner sequence — file in topo-order, never look back. | Doesn't handle partial filings — if the operator says "file only 3 of 5", the cross-refs on the 3 filed ones may point at milestones that were never filed. Brittle. |
| **Single batch via `/tickets-batch`** | One skill call. Existing batching machinery. | `/tickets-batch` is shape-agnostic — it doesn't know about cross-refs at all. Forcing it to handle `blocks` / `blocked by` lines would couple it to `/plan-initiative`'s semantics. Worse, `/tickets-batch`'s body templates don't have a slot for cross-refs (designed for unrelated tickets). |

### Axis 4 — Idempotence semantics on re-run: byte-equivalence vs filed-marker presence vs full regeneration prompt

| Option | Pros | Cons |
|--------|------|------|
| **Filed-marker presence** (re-runs read the prior doc; partition milestones into "carries a `Filed as [#N](url)` marker" (skip silently) vs "no marker" (offer for filing); preserve all prior milestones in the doc; let the operator add new milestones inline) | Matches `/handover` step 7.5's pattern (#376). Composes correctly with the post-filing strikethrough+link rewrite. Operators never get re-prompted on what they've already filed. | The marker matching rule (leading-verb + key-noun-phrase) has to be specified clearly enough that subtle renames don't cause re-prompting. Same constraint #376 faces; same resolution. |
| **Byte-equivalence** (skip the filing step if the regenerated milestone list is byte-equivalent to the prior run's) | Simple to implement | Step 7's own rewrite mutates the section to strikethrough+link forms, guaranteeing every subsequent run's section is NON-byte-equivalent. This is the exact failure mode #376 hit and resolved by switching to filed-marker presence. Don't repeat it. |
| **Full regeneration prompt** (on re-run, ask "regenerate from scratch or update existing?") | Operator-explicit; no inference needed | Friction. Adds a ceremony question to every re-run. Most re-runs are deltas, not regenerations — defaulting to full regeneration prompt makes the common case painful. |

## Decision

**Axis 1**: Socratic interview. Mandatory questions per milestone: name + success criterion + blocks + blocked-by. Optional Socratic questions (operator can defer with "TBD"): kill criterion + value (Low/Med/High) + risk (Low/Med/High) + confidence in time estimate (Low/Med/High). The forcing-function argument (operators commit deeper to plans they articulate) is load-bearing — the cost in interview time IS the value.

**Axis 2**: Single `templates/initiative.md` with inline milestone blocks. Milestone shape is captured as `### Milestone N — Name` headers inside the master doc. DAG renders as one Mermaid `flowchart LR` block at the top of the doc, regenerated on every re-run. Per-milestone artefacts are reserved for the FILED tickets — those use the existing `templates/tickets/feature.md` shape.

**Axis 3**: Two-pass dispatch. Pass 1 dispatches `/feature` per accepted milestone (Title + Body pre-filled from the inline milestone block, omitting cross-ref lines). Pass 2 iterates over the dispatched-and-filed set; for each, computes its inbound + outbound DAG edges restricted to the also-filed set; runs `gh issue edit <N> --body <new body with cross-refs>` to insert `**Blocks**: #X, #Y\n**Blocked by**: #Z` lines below the User Story section. Partial filings work cleanly — cross-refs only span the filed subset. Same per-item y/n filing UX as `/handover` step 7.5.

**Axis 4**: Filed-marker presence, mirroring `/handover` step 7.5. Re-runs read the prior `<slug>.md`, partition milestones into "already filed" (silently skipped) vs "unfiled" (offered for filing). Step 5 (regenerate the milestone list) preserves any prior `~~strikethrough~~ → Filed as [#N](url)` markers across regeneration. Matching rule: leading-verb + key-noun-phrase, same as `/handover` Rule 18.

## Consequences

**For the operator**:

- One new skill: `/plan-initiative <slug>`. Walks them through initiative-level interview → per-milestone Socratic interview → dependency-aware sequencing → optional filing.
- One new template surface: `templates/initiative.md` (overridable via the AgDR-0023 path-mirroring convention; adopters drop `<private_repo>/custom-templates/initiative.md` to customise).
- Initiative docs land at `projects/<name>/initiatives/<slug>.md` (per-project) or `projects/initiatives/<slug>.md` (framework-wide). Scope picked during the interview. Both locations exist today; no new directory conventions.
- Filed milestones become Feature-shape tickets with `**Blocks**: #X` / `**Blocked by**: #Y` cross-references in the body. The tracker reflects the DAG.
- Re-runs surface deltas. Milestones already filed don't get re-prompted. New milestones added since the last run get offered for filing.

**For the framework**:

- No new hooks. The skill writes markdown (exempt from `require-active-ticket.sh`) and dispatches to `/feature` (which manages its own `active-issue-skill` marker per AgDR-0030). No `active-issue-skill` write inside `/plan-initiative` itself.
- No new agents. The Socratic interview runs in the calling thread; no sub-agent dispatch.
- One new entry in the `.claude/skills/` directory + one new template + one new AgDR + a CLAUDE.md skill-table row.
- No `/setup` / `/handover` changes — the skill is invokable standalone; not part of bootstrap.

**For adopters**:

- Single-fork: drop `<fork>/custom-templates/initiative.md` to override the template shape (per AgDR-0023). No other changes.
- Split-portfolio: drop `<private_repo>/custom-templates/initiative.md` to override. `portfolio_resolve_template initiative.md` resolves correctly via `_lib-portfolio-paths.sh` (already implemented; no new resolver work).

**Risks accepted**:

- **Question-bank length**. A 5-milestone initiative with the full optional Socratic question bank is ~25-35 questions. Operators on small initiatives may find it heavy. Mitigation: every optional question accepts "TBD" or empty as a defer-to-later answer. The skill records the deferral; it doesn't loop on it.
- **DAG-cycle detection**. The interview can produce cyclic dependencies if the operator names "M2 blocks M3" AND "M3 blocks M2". The skill detects cycles via Kahn's-algorithm-style topological sort; on cycle, prints the offending cycle and asks the operator to resolve before the sequence step. v1 acceptable: cycle resolution is operator-driven, not auto-broken.
- **Cross-ref rewrite race**. Between pass 1 and pass 2 of the filing step, a teammate could edit one of the just-filed tickets. The pass-2 `gh issue edit --body` rewrites the entire body, potentially clobbering the teammate's edit. Mitigation: pass 2 fetches each filed ticket's current body, splices in the cross-ref lines, and writes back. Race window is small (seconds), but acknowledged.

## Artifacts

- `.claude/skills/plan-initiative/SKILL.md` — the skill (implementation of this design)
- `templates/initiative.md` — the master initiative-doc template (with inline milestone blocks + DAG section)
- `CLAUDE.md` § "Available skills" — new row for `/plan-initiative`
- `.claude/skills/handover/SKILL.md` § 7.5 — the UX mirror for the filing step
- GitHub Issue [#377](https://github.com/me2resh/apexyard/issues/377) — the feature ticket this AgDR implements
- GitHub Issue [#376](https://github.com/me2resh/apexyard/issues/376) — the sibling that established the per-item filing UX pattern

---
id: AgDR-0226
timestamp: 2026-10-11T07:40:00Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: proposed
---

# ORBIT Initiative replaces Plan

> In the context of an ORBIT record called Plan that collides with Claude Code plan mode, the plan-mode rule and /plan-initiative, facing two meanings for "initiative" and one overloaded word for "plan", I decided to rename the ORBIT Plan record to Initiative, to make /plan-initiative the front door that writes an ORBIT Initiative, and to migrate every existing record, to achieve one meaning for each planning term, accepting a spec change in orbit-spec v0.2 and one migration PR per repository.

## Context

- The ORBIT Plan record holds durable intent, outcomes and acceptance criteria. Slices reference it through `planId`, and record IDs start with `plan-`.
- "Plan" also names Claude Code plan mode and the `plan-mode.md` rule. Operators and agents read "plan" in three senses.
- `/plan-initiative` (AgDR-0051) uses "initiative" for a different unit: an initiative document with milestones, a topological sequence and milestone tickets. ORBIT is the default planning flow for this portfolio, so two planning flows use overlapping words.
- ORBIT is at v0.1, before any stable release. On 2026-10-11, 14 records in three repositories have `plan-` IDs, including 2 examples in orbit-spec. Every synced slice issue body also quotes its `plan-` ID (`lib/github-sync.mjs` line 16). The public spec may have adopters this portfolio cannot see.

## Options Considered

### Term

| Option | Pros | Cons |
|--------|------|------|
| Keep Plan | No change | Three meanings of "plan" remain |
| Goal | No collision; the owner's local status pane already uses "goals" | Reads small for multi-outcome work |
| Initiative | Fits multi-outcome, multi-week work; matches how the owner talks about the work | Collides with /plan-initiative unless that skill changes |
| Objective | Common in OKRs | Collides with the Execution Slice `objective` field |

### /plan-initiative

| Option | Pros | Cons |
|--------|------|------|
| Keep it as is | No change | Two meanings of "initiative" |
| Rename it and keep its flow | ORBIT owns the word | Two planning flows remain |
| Make it the ORBIT front door | One entry point and one meaning; keeps the Socratic interview | Retires the milestone and DAG output |
| Retire it | One flow | Loses the interview front door |

### Existing records

| Option | Pros | Cons |
|--------|------|------|
| Keep old IDs; new records use `initiative-` | No migration | Mixed IDs and mixed field names forever |
| Migrate all records | One vocabulary; cheap before v1 with one adopter | One migration PR per repository |

## Decision

Chosen: **Initiative + front door + full migration**, because one meaning per term removes a daily source of confusion. The cost is lowest before ORBIT v1.

- **Spec.** orbit-spec v0.2 renames the `Plan` record to `Initiative` and `planId` to `initiativeId`, with `initiative-` IDs. The CLI gains `orbit initiative`. The validator and the CLI also accept the old names as aliases until every registered repository has migrated, plus one release. orbit-spec records the change in its own AgDR.
- **Front door.** `/plan-initiative` keeps its name and its Socratic interview. It writes an ORBIT Initiative (intent, outcomes, acceptance criteria). It then takes a snapshot, reconciles, and cuts slices.
- **Opt-in stays.** `/plan-initiative` writes ORBIT records whenever an operator runs it, whatever `orbit.default_planning` says. Running it is the opt-in. The flag only controls whether the ticket guard requires a slice record. Adopters with the flag off keep filing tickets freely.
- **Outcomes are the milestones.** Each Initiative outcome gains an optional `dependsOn` list. An entry names an outcome of the same Initiative, or `<initiative-id>#<outcome-id>` for another one. This replaces the milestone graph and its topological order.
- **Slice order follows outcome order.** One slice per outcome (C6 of the token plan) means outcome dependencies order the slices. A slice-level dependency is a different concept and is out of scope here.
- **Kill criterion.** The Initiative gains an optional `killCriterion`: the evidence that stops the whole Initiative. Value and risk scoring is dropped; order comes from `dependsOn` and the operator choice in the interview.
- **One meaning.** "Initiative" in ApexYard means the ORBIT Initiative only. Docs, roles, templates and skills that use the word for anything else change their wording.
- **Migration.** One records PR per repository renames IDs, file names, fields and directories, including `history/` and `archive/`. Git keeps the history. Each slice issue whose body quotes a `plan-` ID gets a one-line alias comment.
- **Rename scope.** The spec, validator and CLI rename `Plan`, `planId`, `planRevision`, `basedOn.planRevision`, the `plans/` directory, the `--plan` flags and `orbit progress --plan`. The validator stops inferring the record kind from the `plan-` filename prefix.
- **One meaning, checked.** A grep check fails on "initiative" outside the ORBIT sense. It exempts CHANGELOG.md, `docs/agdr/` and archived records.
- **Order.** orbit-spec records the spec change in its own AgDR first. This AgDR moves to accepted when that AgDR is accepted.
- **Timing.** Build after the 6 Nov demo scope freeze, so the demo records, the viewer and the pane stay stable. The work is planned as its own ORBIT Initiative.

## Consequences

- This partly supersedes AgDR-0051: the interview stays, and the milestone document, the DAG sequence and milestone tickets are retired.
- `templates/initiative.md` is replaced by the ORBIT Initiative record and its notes file.
- These switch to the new names: the orbit skill and its helpers, `require-orbit-slice-for-ticket.sh`, the `.agents/skills` mirror, the CLI wrapper, the viewer and the pane. Each reads both names during the alias window.
- A branch in flight with old names passes or fails the slice guard depending on whether its migration PR has merged. Migrate each repository when it has no open records PR.
- The orbitspec.dev site and the orbit-spec README change their record list.
- An adopter with ORBIT off loses no planning entry point: `/plan-initiative` still runs, and its records do not turn on the ticket guard.
- The handoff duplicate check reads slice IDs, so issues that quote a `plan-` ID still match their slices.

## Artifacts

- Owner decisions: 2026-10-11 (term Initiative; /plan-initiative becomes the front door; migrate all records; build after 6 Nov).
- Partly supersedes: AgDR-0051.
- Ticket: #1644.
- Matching orbit-spec change: me2resh/orbit-spec#16 (rename the Plan record).
- Challenge: Naqid, 2026-10-11, verdict proceed-with-changes; all seven edits applied.

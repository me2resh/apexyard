---
id: AgDR-0297
timestamp: 2026-11-09T12:00:00Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
category: patterns
---

# A mechanical requirements-traceability check for PRD, design and ORBIT

> In the context of `/design-review` judging requirement coverage by reading, facing a design branch that can hold an old copy of the PRD, we decided to add an advisory `bin/check-traceability.sh` that `/write-spec` and `/design-review` run against the PRD on the base branch, to achieve a repeatable count of uncovered user stories, accepting that the check sees links and not meaning.

## Context

A feature moves through three records. The PRD (`templates/prd.md`) states user stories (`US-n`) and requirements (`FR-n`). The technical design (`templates/technical-design.md`) plans the tasks. ORBIT, when a project uses it, splits the work into slices that deliver acceptance criteria (`acN-M`).

These records did not link to each other. A requirement row did not name its user story. A design task did not name the requirement it delivers. The Solution Architect checked coverage by reading, in the Requirements traceability item of the review lens.

me2resh/apexyard#1749 tested one failure mode:

1. User A cuts a design branch from a PRD with US-1 to US-3.
2. User B merges a PRD change to the base branch that adds US-4.
3. The design PR changes only the design file, so git reports no conflict.
4. The design links to the PRD by path only, so nothing records the PRD version it covers.

In that test, a review that read the PR head judged coverage complete. Two reviews that could read the base branch found US-4. `/design-review` did not say which PRD copy to read.

ORBIT already records the Plan revision that a slice is based on (`basedOn.planRevision`). No record linked a design to a PRD version.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Four new skills for spec, plan, tasks and check | One full chain for large tickets | Duplicates `/write-spec`, the design template, ORBIT slices and `/design-review`. Puts a task list inside one PR. |
| A hook, required CI check or merge-gate condition | Cannot be skipped | Adds a blocking gate for an advisory finding. The maintainer ruled it out on #1749. |
| A new ID scheme for the check | Full control of the format | Two names for one thing. Adopters must learn new IDs. |
| An advisory `bin/` check that reuses `US-n`, `FR-n` and `acN-M`, run from `/write-spec` and `/design-review` | No new skill. No new gate. No new IDs. Works without ORBIT. | Needs a `Serves` column that authors fill in. Sees links, not meaning. |

## Decision

Chosen: **the advisory `bin/` check**, because it closes the tested gap with the records ApexYard already has.

- `bin/check-traceability.sh` reads the PRD from the base branch when `--base` is given. If the current branch changes the PRD itself, it reads the working copy and prints a WARN.
- The PRD template adds a `Serves` column to the requirements table. The check reports a user story with no requirement and a requirement with no user story.
- The design template adds a `Serves` column to the Implementation Plan tasks table. The check reports each user story and requirement that no task serves.
- The design template adds a **PRD version** field with the PRD commit SHA. The check prints a WARN when the PRD on the base branch has a newer commit.
- The PRD template adds an optional Traceability table that maps each user story to ORBIT criteria. With `--orbit`, the check reports each mapped criterion that no slice lists in `contributesTo`. The ORBIT record format does not change.

How this relates to the existing parts:

- `/write-spec` runs the PRD-only check after it saves a draft. It reports gaps to the author and continues.
- `/design-review` reads the PRD from the base branch and runs the full check. Each BLOCK line is a Requirements traceability finding. The reviewer still judges meaning.
- `/design-review` runs the check from the trusted ops fork, never from the PR checkout or a managed-project clone. A PR under review can contain its own `bin/check-traceability.sh`, and the review session holds tracker credentials. The PR's files are only arguments to the check.
- `/orbit` is unchanged. Large work still goes to ORBIT slices, one ticket and one PR each. The check reads slice records and writes nothing.

## Consequences

- A user story that is missing from the design shows as a BLOCK line at design review, before any code exists.
- A PRD change on the base branch after the design was written shows as a WARN line, through the PRD version field.
- The check is advisory. No hook, required CI check or merge gate runs it. A human decides what to do with each finding.
- Authors fill in two `Serves` columns and one PRD version field.
- Old PRDs and old designs give WARN lines, never BLOCK lines. A PRD without a `Serves` column skips the requirement checks. A design whose task rows name no `US-n` or `FR-n` skips the coverage checks.
- A design without a `Serves` column that names IDs in some task rows still gets the coverage check, with a WARN.
- The check sees links, not meaning. A task that names US-2 but does not deliver it passes the check. The review lens still covers that.

## Artifacts

- Ticket: me2resh/apexyard#1749
- Script: `bin/check-traceability.sh`
- Tests: `.claude/hooks/tests/test_check_traceability.sh`
- Templates: `templates/prd.md`, `templates/technical-design.md`
- Skills: `.claude/skills/write-spec/SKILL.md`, `.claude/skills/design-review/SKILL.md`

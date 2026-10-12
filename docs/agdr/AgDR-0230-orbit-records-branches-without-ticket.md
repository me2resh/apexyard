# ORBIT records branches without a ticket

> I decided to exempt verified ORBIT records branches from the ticket rule, with initiative trace links and unchanged merge approval requirements.

## Context

The owner decided on 2026-10-12: "only the next slice gets a ticket, no standing records tickets".
A slice is the next unit of build work in an initiative.
An initiative is an ORBIT Plan record with its outcomes and criteria.
A records PR changes only files under `docs/orbit/`.

This change affects trust-chain controls that check branch names, PR titles, and PR bodies.
These controls are `validate-branch-name.sh`, `validate-pr-create.sh`, the `_lib-review-markers.sh` PR-body profile, and `.github/workflows/pr-title-check.yml`.

[AgDR-0225](AgDR-0225-light-ceremony-for-orbit-records.md) requires a notes line when a check finds no change.
Such checks do not need standing records tickets.
[AgDR-0175](AgDR-0175-dependency-bot-branch-prefix-exemption.md) and [AgDR-0129](AgDR-0129-handover-branch-exemption-and-shadowed-skill-recovery.md) provide precedents for narrow branch exemptions.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep standing records tickets | Keeps the existing ticket rule | Conflicts with the owner decision and adds ticket maintenance |
| Remove the ticket rule for records without a trace link | Removes standing tickets | Loses the link between records and their initiative |
| Use an `orbit/<initiative-id>` branch, a `docs(orbit/<id>)` title, and initiative trace lines | Removes standing tickets and preserves initiative trace links | Requires checks across hooks, CI, and records lint |

## Decision

Chosen: **ORBIT records branches with initiative trace lines**, because this option follows the owner decision and preserves the initiative link.

The branch uses `orbit/<initiative-id>` with a records description suffix.
The `<id>` is the Plan ID without its `plan-` prefix.
The PR title uses `docs(orbit/<id>): <description>`.
The PR body includes the line `Initiative: plan-<id>`.
Each records commit includes the trailer `Initiative: plan-<id>`.

The exemption must fail closed: the checks reject it when they cannot verify a required condition.

- The diff base must use a remote-tracking trunk ref. A local trunk branch cannot supply the base.
- A Plan record must exist on the records branch. The longest matching ID prefix selects the initiative.
- The changed-file list must contain files. No changed file can be outside `docs/orbit/`.
- Missing remote trunk refs, unreadable records, and unreadable diffs reject the exemption.
- The records lint rejects records for another initiative, including records inside `docs/orbit/`.
- The PR-body profile requires the initiative line for the records exemption.

The merge gate remains unchanged.
Every PR still requires Rex approval and explicit per-PR human approval.
The records lint remains required.

Use `git log --grep "Initiative: plan-<id>"` to find commits for an initiative.

## Consequences

- Records PRs no longer need standing tickets when all exemption conditions pass.
- Only the next slice gets a ticket. Build work retains the ticket rule.
- Branch, title, body, and records checks must agree on the initiative ID.
- The exemption reduces ticket maintenance but adds checks for initiative identity and file scope.
- No hook enforces the commit trailer. An omitted trailer reduces the completeness of the git log search.
- Authors must add the trailer. Reviewers must check it until a hook enforces it.
- Human approval remains specific to each PR. This decision does not authorize any merge.

## Artifacts

- Owner decision: 2026-10-12.
- Ticket: [#1673](https://github.com/me2resh/apexyard/issues/1673).
- PR: [#1675](https://github.com/me2resh/apexyard/pull/1675).
- Controls: `.claude/hooks/validate-branch-name.sh`, `.claude/hooks/validate-pr-create.sh`, `.claude/hooks/_lib-review-markers.sh`, and `.github/workflows/pr-title-check.yml`.

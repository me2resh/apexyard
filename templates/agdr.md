---
id: AgDR-{NNNN}
timestamp: {ISO-8601: YYYY-MM-DDTHH:MM:SSZ}
agent: {agent-name}
model: {model-id}
session: {session-id}
trigger: {user-prompt | hook | automation}
status: {executed | rolled-back | superseded by AgDR-NNNN}
# Optional — read by /agdr for portfolio-wide indexing. Safe to omit;
# legacy AgDRs without this field land in the `other` bucket.
# category: architecture | tech-stack | security | patterns | integrations | other
# recording: back-filled   # only for /decide --backfill
# original_decision_date: {known date, approximate date, or unknown}
# projects: [<project-name>]   # optional; defaults to the AgDR's containing project
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# {Short Title}

> In the context of {context}, facing {concern}, I decided {decision} to achieve {goal}, accepting {tradeoff}.

## Context

{Decision-relevant context only -- what influenced this choice}

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| {option 1} | {pros} | {cons} |
| {option 2} | {pros} | {cons} |

## Decision

Chosen: **{option}**, because {justification}.

## Consequences

- {consequence 1}
- {consequence 2}

## Artifacts

- {commit/PR/deployment links}

<!-- Backfill instructions: Apply these instructions only for /decide --backfill.
Mark the title "back-filled". Enable recording: back-filled in frontmatter.
Use timestamp for the writing date and time. Record the original choice date separately.
Keep Context, Options Considered, Decision, Consequences, and Artifacts.
Replace the options table with "Unknown: no comparison confirmed" unless the person confirms an earlier comparison.
Use the summary to describe the earlier choice. Do not imply a new decision today.
Under Decision, add "### Remembered reasons" with the person's recollections.
Under Consequences, add "### Known limits" and "### Change triggers".
Change triggers state what would make the team change the tool.
State unknown information explicitly. Keep each section brief.
Remove these instructions and unused placeholders from the final record.
-->

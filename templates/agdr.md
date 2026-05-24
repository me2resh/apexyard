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
# projects: [<project-name>]   # optional; defaults to the AgDR's containing project
---

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

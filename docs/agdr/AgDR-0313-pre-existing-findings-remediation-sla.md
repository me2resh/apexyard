---
id: AgDR-0313
timestamp: 2026-11-21T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: n/a
trigger: user-prompt
status: executed
category: security
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Pre-existing security findings follow a remediation SLA

> In the context of review findings that the change did not introduce (issue #2095, PR #2098), facing a rule that blocked every PR for any Critical or High finding, I decided that a Pre-existing security finding does not block the PR and follows a remediation SLA, to keep unrelated PRs moving while the finding still gets fixed on a deadline, accepting that a Pre-existing Critical finding can stay open for up to 7 days.

## Context

Before this decision, Hakim blocked the PR for every Critical or High finding.
This included a finding that existed on the base branch before the PR.
The author of an unrelated PR could not merge until someone fixed an old problem.
The owner decided on 21 November 2026 how to handle such findings.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Always block the PR | Simple. No old finding stays open | An unrelated PR waits for an old problem. The author may fix it badly under pressure |
| Ticket, and an immediate release block | The PR merges. A release stays safe | An old finding can stop a release at once, with no time to fix it |
| Ticket with a remediation SLA by severity | The PR merges. The finding has a due date. A release blocks only after a breach | A Pre-existing finding can stay open until its SLA ends |

## Decision

Chosen: **Ticket with a remediation SLA by severity**, because it keeps the fix accountable without blocking unrelated work.

- A Pre-existing security finding does not block the PR.
- It gets a ticket due on its first-seen date plus its severity SLA.
- It blocks a release only after the SLA is breached.
- Default SLAs: Critical 7 days, High 30 days, Medium 90 days, Low no SLA (advisory).
- Adopters set the SLAs in `.security.remediation_sla_days` in the project config.
- A Critical or High finding that the change introduced or worsened still blocks the PR.
- All other security rules stay the same.
- A Pre-existing Critical, High or Medium line in a review states `SLA: N days. Due: YYYY-MM-DD`. The tally validator checks this.

## Consequences

- Hakim, the `/security-review` skill and `templates/REVIEW.md` state one identical SLA sentence.
- Hakim must show base evidence that a finding is Pre-existing. A finding with unknown provenance stays unverified and is not tagged Pre-existing.
- AgDR-0301 is superseded in part. Its CRITICAL and HIGH blocks apply to findings that the change introduced or worsened.
- Adopters with a custom `REVIEW.md` must follow the upgrade note in `docs/skills/drive-to-green.md`.
- A release process must check open Pre-existing tickets against their due dates.

## Artifacts

- Issue me2resh/apexyard#2095
- PR me2resh/apexyard#2098

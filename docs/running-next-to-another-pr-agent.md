# Run ApexYard next to another PR agent

ApexYard works with any coding agent. It also works next to any review agent that comments on or approves a pull request. This guide explains what counts as the human approval and how to set up the forge.

## What counts as the human approval

The merge gate does not read approvals from the forge. A bot or app approval on the PR never counts as the human approval.

The gate reads one record. `/approve-merge` writes that record after a person approves that PR at its head commit. The record must hold `approved_by=user` and the head SHA. See `.claude/hooks/block-unreviewed-merge.sh` and `.claude/skills/approve-merge/SKILL.md`.

A new commit makes the record stale. The person must approve again.

## Set up branch protection

The record is a local file. Its write gate is a backstop, not a security boundary (AgDR-0109). Server-side branch protection is the hard control.

On each protected branch, turn on these settings:

1. Require one approving review from a person.
2. Dismiss stale approvals when a new commit arrives.
3. Require the ApexYard check, `Verify Rex Review`. The job comes from `golden-paths/pipelines/review-check.yml`.
4. Require the other CI checks of your project.

See also the [threat model](../SECURITY.md#threat-model).

## Treat other agent output as advisory

Approvals and review comments from another agent are advisory input. A person weighs that input. It never satisfies a gate.

A gate reads only the records that the framework defines. An approval from another agent adds no record.

## Record each accepted call

Write an Agent Decision Record (AgDR) when you accept a call from such a review. Use the `/decide` skill or copy [`templates/agdr.md`](../templates/agdr.md). State the review comment, the decision, and the reason.

## Related

- [Escalation pattern](escalation-pattern.md)
- [Rule audit](rule-audit.md)
- [Getting started](getting-started.md#turn-on-branch-protection)

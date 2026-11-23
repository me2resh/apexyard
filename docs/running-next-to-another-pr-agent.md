# Run ApexYard next to another PR agent

ApexYard runs with Claude Code, and with other coding agents through an adapter. See the README adapter table and `docs/harnesses/` for the proof and limits of each adapter. For example, the Cursor IDE runs the same gates only when third-party configs are on (`docs/harnesses/cursor.md` line 9). The `cursor-agent` CLI has no coverage (`docs/harnesses/cursor.md` line 15). The opencode and pi adapters skip the merge gate for a command that starts with `cd` (`docs/harnesses/opencode.md` line 66, `docs/harnesses/pi.md` line 52). ApexYard also runs next to any review agent that comments on or approves a pull request. This guide explains what counts as the human approval and how to set up the forge.

## What counts as the human approval

The human half of the merge gate never reads approvals from the forge. A bot or app approval on the PR never counts as the human approval.

The human half reads one record. `/approve-merge` or the approval menu writes that record after a person approves that PR at its head commit. The record must hold `approved_by=user` and the head SHA. See `.claude/hooks/block-unreviewed-merge.sh` lines 20-46 and 702-736, `.claude/skills/approve-merge/SKILL.md`, and `record-menu-approval.sh` (AgDR-0234).

The optional `review_markers.require_posted_review` setting does read posted forge reviews. It checks the agent-review half only. See `.claude/hooks/block-unreviewed-merge.sh` lines 496-606 and `.claude/hooks/_lib-tracker.sh` lines 2041-2049.

A new commit on the PR branch makes the record stale. The person must approve again. One exception exists. A conflict-free merge of the base branch, checked on the forge, keeps the approval. See `.claude/hooks/block-unreviewed-merge.sh` lines 794-825 and AgDR-0178.

## Set up branch protection

The record is a local file. Its write gate is a backstop, not a security boundary (`docs/agdr/AgDR-0109-marker-write-gate-is-a-backstop.md`). Server-side branch protection is the hard control (`SECURITY.md` line 46).

On each protected branch, turn on these settings:

1. Require one approving review. Limit who can approve, for example with code owners who are people. Turn off approvals from apps and bots where the forge allows it. An app or bot with write access can count toward the forge's required review. This is forge configuration advice. ApexYard did not test it.
2. Dismiss stale approvals when a new commit arrives (`docs/release-process.md` lines 263-269).
3. Copy `golden-paths/pipelines/review-check.yml` to `.github/workflows/review-check.yml` in your project. The check never reports until that file runs. Then require the job `Verify Rex Review` (`golden-paths/pipelines/review-check.yml` line 20).
4. Require the other CI checks of your project.

See also the [threat model](../SECURITY.md#threat-model).

## Treat other agent output as advisory

Approvals and review comments from another agent are advisory input. A person weighs that input. It never satisfies the human half of the gate.

The human half reads only the record that the framework defines. An approval from another agent adds no record.

## Record each accepted call

Write an Agent Decision Record (AgDR) when you accept a call from such a review. Use the `/decide` skill or copy [`templates/agdr.md`](../templates/agdr.md). State the review comment, the decision, and the reason.

## Related

- [Escalation pattern](escalation-pattern.md)
- [Rule audit](rule-audit.md)
- [Getting started](getting-started.md#turn-on-branch-protection)

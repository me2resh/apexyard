# SHA-bound pre-merge QA reuse

> In the review workflow, I chose a SHA-stamped PR comment for optional QA results. This lets post-merge QA reuse a complete PASS on the same commit. The trade-off is another QA run when merge changes the SHA.

## Context

Rex approves a PR before merge. The current QA trigger labels the ticket after merge.
Adopters need an optional QA check before code reaches the base branch.
The offer cannot grant merge approval or change the human merge gate.
Post-merge QA needs durable evidence when the earlier check covered the merged commit.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Store QA PASS in a local marker | Easy to read in one workspace. | Other workspaces cannot see it. It resembles merge approval state. |
| Post a SHA-stamped QA comment on the PR | Visible after merge. Works with the existing comment adapter. | Exact SHA matching reruns QA after squash or merge commits. |
| Add a mandatory QA merge gate | Blocks every merge without QA. | Removes the adopter's choice and exceeds this issue's scope. |

## Decision

Chosen: **post a SHA-stamped QA comment on the PR**, because the post-merge role can inspect the same durable record.
The comment includes each acceptance criterion and its evidence. Only a complete PASS can be reused.
Post-merge QA compares the recorded SHA with the exact merged commit SHA.
The offer remains advisory. It never writes a merge marker or invokes a merge.

## Consequences

- `qa.pre_merge_offer` defaults to `ask`. Adopters can select `always` or `never`.
- A declined offer keeps the existing post-merge QA run.
- A failed pre-merge check stops the review handoff before it requests human merge approval.
- A changed SHA or incomplete report requires a new QA run after merge.
- Human approval remains with `/approve-merge`.

## Artifacts

- Issue #1383
- `.claude/skills/code-review/SKILL.md`
- `.claude/agents/qa-engineer.md`
- `roles/engineering/qa-engineer.md`
- `.claude/hooks/tests/test_pre_merge_qa_offer.sh`

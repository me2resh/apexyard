# SHA-bound pre-merge QA reuse

> Post-merge QA reuses a complete PASS from a trusted author when its stamp matches the merged PR's final head SHA. A later push invalidates an earlier PASS.

## Context

Rex approves a PR before merge. The current QA trigger labels the ticket after merge.
Adopters need an optional QA check before code reaches the base branch.
The offer cannot grant merge approval or change the human merge gate.
Post-merge QA needs durable evidence that the earlier check covered the PR's final head.

The `/approve-merge` skill uses squash merging by default.
GitHub creates a new SHA for the squash commit, so a merge-commit comparison prevents reuse.

On public repositories, anyone can post a comment or review containing a PASS marker.
The marker alone cannot establish author trust.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Store QA PASS in a local marker | Easy to read in one workspace. | Other workspaces cannot see it. It resembles merge approval state. |
| Post a QA comment bound to the final head SHA | Visible after merge. Uses the same head binding as Rex and CEO merge markers. | Requires checking the final head, author trust, and criterion evidence. |
| Bind reuse to the merge-commit SHA | Identifies the commit on the base branch. | Never matches the pre-merge stamp after squash on GitHub. Rebase and merge commits also get new SHAs. |
| Compare tree SHAs | Equal trees mean identical code when the branch was up to date. | Harder to explain and verify from the tracker alone. |
| Add a mandatory QA merge gate | Blocks every merge without QA. | Removes the adopter's choice and exceeds this issue's scope. |

## Decision

Chosen: **post a SHA-stamped QA comment on the PR**, because the post-merge role can inspect the same durable record.
The comment includes each acceptance criterion and its evidence. Only a complete PASS can be reused.

Reuse a complete pre-merge QA PASS only when its stamped SHA matches the merged PR's final head SHA.
This is the PR head commit when it merged (the MR head SHA on GitLab).
A PASS stamped with an earlier head does not count.
Accept reports only from the repository owner, a member or a collaborator, or the account that posted the Rex review.
On GitHub, verify `author_association` of `OWNER`, `MEMBER` or `COLLABORATOR`, or the Rex account match.
Otherwise, run post-merge QA as usual.

This uses the same head binding as the Rex and CEO merge markers.
On GitLab, verify equivalent repository access or the Rex account match.
Reject merge-commit SHA binding because it prevents reuse after GitHub squash merges.
Reject tree-SHA comparison because it is harder to explain and verify from the tracker alone.
The offer remains advisory. It never writes a merge marker or invokes a merge.

## Consequences

- `qa.pre_merge_offer` defaults to `ask`. Adopters can select `always` or `never`.
- A declined offer keeps the existing post-merge QA run.
- A failed pre-merge check stops the review handoff before it requests human merge approval.
- Reuse happens whenever QA ran on the final head and the report satisfies the trust and evidence requirements.
- This is the normal case when QA runs after the last Rex re-review, including with squash, rebase, or merge commits.
- A later push invalidates an earlier PASS because it changes the head.
- An untrusted author, incomplete evidence, or an unverifiable final head requires a new QA run after merge.
- Human approval remains with `/approve-merge`.

## Artifacts

- Issue #1383
- `.claude/skills/code-review/SKILL.md`
- `.claude/agents/qa-engineer.md`
- `roles/engineering/qa-engineer.md`
- `.claude/hooks/tests/test_pre_merge_qa_offer.sh`

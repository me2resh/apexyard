# Allow orchestration to provision review worktrees

> In the context of an active review window, facing the read-only control blocking the only actor that can create the reviewer's isolated checkout, I decided to allow `git worktree add` while continuing to block changes to existing worktrees, to preserve reviewer isolation without deadlocking review setup.

## Context

AgDR-0145 made repository mutation unavailable while the active-reviewer marker exists. The control correctly prevents a reviewer from changing the reviewed checkout, but it also blocks the orchestrator from running `git worktree add`. The documented review flow writes the marker before it starts the reviewer, so no actor can provision a fresh isolated checkout after that point.

`git worktree add` creates a separate checkout. It does not alter the reviewed worktree or its index. Operations that alter or remove an existing worktree remain blocked.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Require provisioning before the marker | No hook change | The ordering constraint is easy to miss and leaves no recovery path when a reviewer needs a new checkout. |
| Add an orchestrator identity signal | Could distinguish the intended actor | No reliable actor signal is available to this hook at command time. |
| Allow `git worktree add`; keep existing-worktree changes blocked | Restores isolated-review setup and preserves the author/reviewer boundary | Worktree creation can create a branch reference, so the operation remains a controlled exception. |

## Decision

Chosen: **allow `git worktree add` while blocking existing-worktree operations**, because the command provisions the isolated review surface and does not change the builder's checkout. The hook continues to block `lock`, `move`, `prune`, `remove`, `repair`, and `unlock` while a review is active.

## Consequences

- The orchestrator can provision a reviewer worktree after setting the active-reviewer marker.
- A reviewer cannot alter or remove an existing worktree during the review.
- Branch creation through `git worktree add -b` is an accepted, visible exception needed to provision an isolated branch.
- The focused hook test records the allowed and blocked worktree subcommands.

## Artifacts

- `.claude/hooks/block-reviewer-repo-mutation.sh`
- `.claude/hooks/tests/test_block_reviewer_repo_mutation.sh`
- Issue #1272

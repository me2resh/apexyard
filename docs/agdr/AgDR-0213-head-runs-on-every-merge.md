# AgDR-0213 — Check head workflow runs on every GitHub merge

> I decided to check workflow runs for the PR head on every GitHub merge. This closes gaps in the CI gate. It adds one Actions API call per merge and keeps API failures fail-open with an honest note.

## Context

`gh pr checks` can pass while a separate head workflow run waits for approval or execution. The prior hook checked runs only when `gh pr checks` reported no checks. It also called some API failures "no CI checks configured."

This decision refines AgDR-0201 and AgDR-0212. It does not supersede either record. AgDR-0212 preserved the exact no-checks match and the allow for a repository with no CI.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Keep the no-checks-only query | No added call on green merges. | Allows unseen pending or failed runs when other checks pass. |
| Query head runs on every merge | Checks runs that `gh pr checks` cannot show. | Adds one Actions API call per merge. |
| Block when the Actions API fails | Prevents an unverified merge. | Changes the established fail-open policy during API faults. |

## Decision

Chosen: **query head runs on every GitHub merge**, accepting one extra Actions API call per merge (A2 and A5).

Use one `head_sha=<sha>&per_page=100` runs request. Block on `action_required`, any status other than `completed`, or a completed conclusion outside `success`, `neutral`, and `skipped`. Name each blocking workflow and its state. Block if the response reports more runs than the page contains.

Evaluate only the latest run per `workflow_id`, choosing the highest `run_number` and breaking ties by `created_at`, then run `id`. PR edits can start another run on the same head, and `cancel-in-progress` can leave an older cancelled run; those superseded results must not decide the merge.

Keep Actions API failures fail-open (A3). A permission error, rate limit, network fault, invalid JSON, or missing field cannot prove a run failed. Print a note that the gate could not check CI state. Never call an API failure "no CI checks configured."

If the workflow inventory succeeds but the runs request fails or returns a non-number count, print the same unverified note (N1). Require the exact head SHA filter in the test stub (N2). Validate `owner/repo` and the 40-character hexadecimal head SHA before placing them in an API path (N3). Block malformed values because the merge command or PR lookup supplied them.

Keep the exact no-checks branch from AgDR-0212. Allow a repository with no checks and no head runs when its workflow inventory is empty. Report that workflows exist when filters leave this head with no runs.

## Consequences

- A pending, gated, or failed head run blocks even when other checks pass.
- An Actions API fault still allows the merge, but the note states that CI remains unverified.
- Invalid repository or head identifiers block before the Actions request.
- A partial runs page cannot prove all runs passed. The gate blocks until it can inspect every head run.

## Artifacts

- Issue: me2resh/apexyard#1536
- Hook: `.claude/hooks/block-merge-on-red-ci.sh`
- Tests: `.claude/hooks/tests/test_block_merge_on_red_ci.sh`

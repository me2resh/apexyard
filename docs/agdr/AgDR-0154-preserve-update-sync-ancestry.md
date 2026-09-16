# Preserve ancestry when merging update sync PRs

> In the context of `/update` creating `chore/(#<TICKET>-)?sync-upstream-*` branches with a merge from upstream, facing the risk that `/approve-merge` and direct merge commands squash away the ancestry link, I decided to classify `/update` branches and titles as sync PRs and require a true merge commit, accepting that these PRs cannot use squash or rebase.

## Context

- `/update` creates a sync branch and merges the upstream ref into it.
- The resulting merge commit records upstream as an ancestor of the fork.
- `/approve-merge` previously auto-selected squash because its sync detection only matched `/release-sync` branches.
- Squashing or rebasing can preserve content while discarding the ancestry closure that the next update relies on.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep `/update` branch names and default to squash | No skill or gate changes | Repeats the ancestry regression and makes update status drift |
| Detect `/update` sync shapes and require merge | Preserves ancestry through the normal approval flow and direct merge backstop | Sync PRs must use merge commits |
| Rename `/update` branches to `sync/*` | Reuses the existing detector | Changes the documented branch convention and can disrupt adopters' scripts |

## Decision

Chosen: **detect `/update` sync branches and titles as sync-class and require `--merge`**, because the existing branch convention is established and the merge commit is the durable ancestry link. `/approve-merge` selects `merge`, and `block-unreviewed-merge.sh` blocks squash and rebase for both `/release-sync` and `/update` shapes.

## Consequences

- `/update` documentation states that its sync PRs must use a true merge commit.
- Direct `gh pr merge` and API merge attempts cannot bypass the strategy requirement.
- Existing non-sync PRs retain the default squash strategy.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1301
- `.claude/skills/approve-merge/SKILL.md`
- `.claude/skills/update/SKILL.md`
- `.claude/hooks/block-unreviewed-merge.sh`
- `.claude/hooks/tests/test_block_unreviewed_merge.sh`
- `.claude/skills/approve-merge/tests/test_merge_invocation_not_substituted.sh`

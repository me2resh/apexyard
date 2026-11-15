---
id: AgDR-0301
timestamp: 2026-11-15T12:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# Clean up a merged PR's worktree and review copies in one proposal

> After a merge, `/approve-merge` proposes the removal of the PR worktree, its review copies and their build output in one question.
> The helper finds a review copy only from `git worktree list`, as a detached HEAD at a commit of the PR.
> Every removal is logged. The cost is that standalone scratch clones stay on disk until a later step.

## Context

Issue [#2070](https://github.com/me2resh/apexyard/issues/2070) reports about 113 GB of disk use on one machine.
Review and QA copies of merged PRs used about 20 GB.
Worktrees of merged PRs used about 14 GB.
Build output inside worktrees used 15 GB or more.

Step 1 of #2070 asks for clean-up at merge.
The owner set these rules:

- Propose first. Remove only after the user says yes.
- Never use `--force`.
- Skip a dirty tree.
- Never remove a path that the helper did not list.
- Log each removal.
- Do not loosen or remove any existing check.

[AgDR-0222](AgDR-0222-ticket-marker-in-worktree-git-dir.md) added the step 9a worktree offer.
[AgDR-0286](AgDR-0286-cleanup-owner-preservation-checks.md) added the owner and preservation checks.
Step 9a found only the worktree that holds the PR head branch.

A reviewer makes a review copy in one of three ways:

1. `git worktree add <path> <sha>`. This makes a linked worktree with a detached HEAD.
2. `git clone` into a temp folder.
3. `git archive` into the session scratchpad.

## Options Considered

How to find review copies:

| Option | Pros | Cons |
|--------|------|------|
| Detached linked worktrees at a PR commit, from `git worktree list` (chosen) | Git lists the candidates. The existing refusal rules apply unchanged. | Standalone clones and exports are not found. |
| Scan temp folders for clones of the repo | Finds more copies. | No record ties a clone to a PR. A scan can match user files. |
| Wait for the known copy folder of step 3 | One location for every copy. | No review copy is removed at merge until step 3 ships. |

How to match a review copy to the PR:

| Option | Pros | Cons |
|--------|------|------|
| HEAD equals the merged head or a given PR commit (chosen) | Exact. No match on a base-branch commit. | The skill must pass the PR commit list for earlier review rounds. |
| HEAD is an ancestor of the merged head | No commit list needed. | Every base-branch commit is an ancestor. A copy at `main` would match. |

Where to keep the log:

| Option | Pros | Cons |
|--------|------|------|
| `<ops-root>/.claude/session/cleanup.log` (chosen) | Gitignored. Per clone. The helper already resolves the ops root. | Lost when the session folder is cleared. |
| A tracked file | Durable. | Adds machine paths to git history. |

## Decision

Chosen: **two new helper modes, `list-copies` and `remove-copy`, plus a removal log for every remove mode**.

- `list-copies <source-tree> --merged-head <sha> [--pr-commit <sha>]...` lists linked worktrees with a detached HEAD at one of the given commits.
  The merged head is required.
  The output format is the same as `list`.
- `remove-copy` rechecks that git still lists the path.
  It rechecks that the HEAD is still detached at one of the given commits.
  It then runs the same refusal function as `remove`.
- A worktree that holds a branch is never a review copy.
- The `list` and `remove` modes keep their arguments, refusals, order and output.
- Both remove modes append one tab-separated line to the log after git removes the worktree.
- Both remove modes refuse before removal when they cannot append to the log.
  This is a new refusal. It makes the existing modes stricter, not looser.
- Build output is the set of ignored files in a worktree.
  `git worktree remove` deletes it with the worktree.
  The list modes show it in the proposal.
- The skill proposes all `ok` rows in one `AskUserQuestion`.
  The two list commands are the dry run.

Closed PRs that were not merged are out of scope for this step.
The framework has no PR close flow, and the merged-head rule needs a merged head.

## Consequences

- One merge can reclaim the PR worktree, the review copies and their build output after one yes.
- A review copy from an earlier round is found only when the skill passes its SHA with `--pr-commit`.
- An earlier commit is preserved only when it is an ancestor of the merged head or a remote holds it.
  A commit lost to a force push is refused as `unpushed commits`.
- Standalone scratch clones and `git archive` exports stay on disk.
  Step 3 of #2070 puts all copies under one known folder with a record.
  Step 4 adds a sweep for that folder.
- The log is per clone and gitignored.

## Artifacts

- `.claude/skills/approve-merge/remove-worktree.sh`
- `.claude/skills/approve-merge/SKILL.md` step 9a
- `docs/skills/approve-merge-worktree-offer.md`
- `.claude/hooks/tests/test_cleanup_at_merge.sh`

# AgDR-0286: Check ownership and preservation before worktree cleanup

## Context

Issue #1940 requires cleanup to protect active writers and work that has no preserved copy.
The owner API from AgDR-0284 supplies ownership status and a record generation.
A generation identifies one revision of an owner record.
Remote-tracking refs record remote branches in the local clone.

Squash merges create a new commit on the target branch.
Deleting the remote source branch can leave the original PR commits outside every remote-tracking ref.
A strict remote-ref check would then refuse legitimate post-merge cleanup.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Keep location checks only | Small implementation | Can remove active or unpreserved work |
| Require remote refs for every commit | Conservative preservation check | Refuses squash-merged work after branch deletion |
| Check owners and preservation with a verified merged-head exception | Protects work and supports squash merges | Requires the verified PR head |

## Decision

The cleanup helper preserves every existing refusal and its order.
It checks path availability, resolved session and ops paths, main worktree, lock, session tree, and containment of the ops root.
It then checks ownership before preservation.

The helper uses `worktree_owner_status` from the public owner API.
An `alive` owner refuses cleanup, unless that owner is the calling session, as defined below.
An `unknown` owner refuses cleanup and tells the operator to inspect the owner record before any release.
`dead`, `none`, and `released` continue.
Missing owner code or `jq` refuses every otherwise eligible candidate with `owner check unavailable`.
Unexpected status output or return codes also refuse cleanup.

`/fan-out` records its calling session as the owner of each writer worktree.
Without an exception, that session could not clean up its own merged worktree while it runs.
The calling session owns a worktree when the active record's owner equals its full identity from `worktree_owner_identity`.
That identity is the session id, harness, process id, process start, and boot identity.

A session-only identity has no process evidence and never matches.
Another live session never matches.
The uncommitted-change and unpushed-commit checks still apply.

After the operator's yes, the helper releases the record with `worktree_owner_release`, which re-checks the owner under the record lock.
If the release fails, the helper refuses.
If Git then refuses the removal, the helper acquires the record again.
If that also fails, the helper warns and the record stays released.

`none` continues, as it does without this change.
A worktree with no owner record gets no owner protection.
That covers worktrees created before owner records existed and worktrees created by the harness.
This change records no owners for harness-created worktrees.

Preservation checks inspect Git status without refreshing the index or invoking FSMonitor.
Changes reported by Git status refuse cleanup, including an untracked `owner.json`.
Ignored files remain subject to the separate removal confirmation.
Any remote-tracking ref may preserve commits, even without a configured upstream branch.
An unavailable status or commit check refuses cleanup.

The optional `--merged-head <sha>` argument identifies the verified merged PR head.
The skill passes this argument during listing and removal.
An otherwise unpushed `HEAD` counts as preserved only when it equals or is an ancestor of that commit.
The helper verifies this relationship with `git merge-base --is-ancestor`.
Without the argument, cleanup requires remote-ref preservation.
The exception never permits dirty worktrees or bypasses owner checks.

For an unknown owner, the skill shows one owner-record snapshot and its generation.
It asks the operator with `AskUserQuestion` before releasing that record.
The procedure permits `worktree_owner_force_release <worktree> <generation>` only after an explicit yes.
Never offer this procedure for an `alive` owner.

The library rereads the record under the existing owner lock.
It requires an active record with the shown generation and refuses an owner that is now alive.
A mismatch leaves the record byte-for-byte unchanged.
A successful write sets `status: released`, `owner: null`, `released_by` to the caller identity, and `forced: true`.

The successful write increments the generation once and preserves the lease timestamps.
Later normal owner writes clear the forced-release flag.
The skill then lists candidates again and asks separately before removal.

## Consequences

Cleanup now requires the owner library and `jq`.
The helper repeats all checks immediately before invoking Git removal without force.
The checks and Git removal are separate operations.
They do not prevent another writer from starting between those operations.
Generation checks inherit the directory-lock limits documented in AgDR-0284.

The operator confirmation is procedural and the library does not enforce it.
Any caller can run `worktree_owner_force_release` or edit the record directly.
A force release can release an owner that is still running.
The operator should check the shown process first.

The helper trusts the skill to supply the verified merged PR head.
It does not query the remote host to prove a merge.
Local remote-tracking refs can be stale.
This change adds no owner registry, automatic release, or lease-expiry takeover.
The helper releases only the calling session's own record.
The skill runs `remove` only after the operator's yes, and the helper cannot check that.
A session whose id changed after it took ownership no longer matches, so its worktree stays refused while that process runs.

## Artifacts

- Refs #1940
- `.claude/skills/approve-merge/remove-worktree.sh`
- `.claude/skills/approve-merge/SKILL.md`
- `docs/skills/approve-merge-worktree-offer.md`
- `.claude/hooks/_lib-worktree-owner.sh`
- `.claude/hooks/tests/test_approve_merge_worktree.sh`
- `.claude/hooks/tests/test_lib_worktree_owner.sh`

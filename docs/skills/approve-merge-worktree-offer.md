# /approve-merge step 9a: offer to remove the merged worktree and review copies

This is the full text of step 9a. The skill keeps a short form.

## 9a. Optional: offer to remove the merged PR's worktree and review copies

Skip this step when `MERGE_RC` is not 0, and when `--no-merge` was passed.

A merged PR often leaves a linked worktree on disk. Removing it also removes its ticket marker, because the marker lives in the worktree's git dir. Offer the removal. Never do it without a yes.

The step covers three items in one proposal (#2070):

- The **PR worktree**: a linked worktree that holds the PR's head branch.
- The **review copies**: linked worktrees with a detached HEAD at a commit of the PR. A reviewer or QA engineer makes them with `git worktree add <path> <sha>`.
- The **build output**: the ignored files in each of these worktrees. `git worktree remove` deletes them with the worktree.

A standalone scratch clone or a `git archive` export is not a linked worktree. The helper does not find it. Leave it for a later sweep.

1. Find the local clone of the PR's repo, the **source tree**. For a registered project it is `workspace/<name>/`, or the `workspace:` path of its registry entry. For a PR on the ops fork it is the ops root.
2. List the candidates with the helper.
   Use the merged PR's head branch and the verified merged head from step 4 for `<merged-head-sha>`:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh list "<source-tree>" "<head-branch>" --merged-head "<merged-head-sha>"
   ```

   The helper takes candidates only from `git worktree list --porcelain -z`.
   It runs this command with `-C` on the validated common dir.
   The `-z` option needs git 2.36 or later.
   With an older git, the helper lists no worktree, prints an error and removes nothing.
   Tell the user that the worktree stays on disk.
   The helper prints `ok` or `refused (<reason>)` for each worktree that holds the branch.
   It lists ignored files for each `ok` worktree.

   The helper applies these checks in order:

   - The path must exist.
   - The session tree and ops root must resolve.
   - The path must not be the main worktree.
   - The worktree must not be locked.
   - The path must not be the session's own tree.
   - The path must not equal or contain the ops root.
   - The owner must be `dead`, `none`, or `released`, or be the calling session.
   - The worktree must have no uncommitted changes.
   - Remote-tracking refs must preserve every commit, unless the merged-head rule applies.

   The calling session owns a worktree when the owner record matches its full identity.
   That identity is the session id, harness, process id, process start, and boot identity.
   `/fan-out` records its calling session this way.
   Another live session's worktree stays refused.

   A remote-tracking ref is a local record of a remote branch.
   The merged-head rule accepts an unpushed `HEAD` equal to, or an ancestor of, `HEAD_SHA`.
   This rule supports squash merges followed by remote branch deletion.
   Without `--merged-head`, unpushed commits always refuse cleanup.
   A missing owner library or `jq` refuses cleanup with `owner check unavailable`.
   An inconclusive preservation check also refuses cleanup.
   For an `owner unknown` refusal, follow the release procedure below.
3. List the review copies with the helper.
   Use the same `<merged-head-sha>`.
   Add one `--pr-commit` argument for each other commit SHA of the PR, if the tracker gives them.
   For GitHub, `gh pr view <pr> --repo <owner/repo> --json commits --jq '.commits[].oid'` prints them.

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh list-copies "<source-tree>" --merged-head "<merged-head-sha>" --pr-commit "<pr-commit-sha>"
   ```

   The helper lists a linked worktree only when its HEAD is detached at one of these commits.
   It never lists a worktree that holds a branch.
   It prints the same `ok` and `refused (<reason>)` rows and applies the same checks as `list`.
   An earlier commit counts as preserved only when it is an ancestor of the merged head or a remote holds it.
   The output of the two list commands is the dry run. It removes nothing.
4. If there is an `ok` row, propose the removal with `AskUserQuestion`.
   Show each `ok` path and its kind: PR worktree or review copy.
   Show the ignored files that the helper listed, because `git worktree remove` deletes them.
   Show each `refused` row with its reason, and say that it stays on disk.
   Offer "Remove them" and "Keep them".
5. On "Remove them", run one command for each `ok` path.
   For the PR worktree, run:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh remove "<source-tree>" "<path>" "<head-branch>" --merged-head "<merged-head-sha>"
   ```

   For a review copy, run:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh remove-copy "<source-tree>" "<path>" --merged-head "<merged-head-sha>" --pr-commit "<pr-commit-sha>"
   ```

   Pass the same `--pr-commit` arguments as in step 3.
   The `remove-copy` command rechecks that the HEAD is still detached at one of the given commits.
   It then rechecks every refusal rule.

   The helper rechecks the branch and every refusal rule.
   When the calling session owns the worktree, the helper releases that record with `worktree_owner_release`.
   If the release fails, the helper refuses.

   The helper runs `git worktree remove` with no `--force`.
   If Git refuses, the helper acquires the record again.
   If that also fails, the helper warns and the record stays released.
   A dirty worktree stops the step.
   Report the helper's message.
   Leave a refused worktree for the user.

   Each removal appends one line to the removal log `<ops-root>/.claude/session/cleanup.log`.
   The line has these tab-separated fields: UTC time, kind, path, source tree, branch or HEAD, and merged head.
   The kind is `worktree` or `review-copy`.
   The helper refuses before it removes anything when it cannot write the log.
   After the removals, tell the user the removed paths and the log path.
6. On "Keep them", do nothing. Do not ask again.

Never remove a path that the helper did not list. Never pass `--force`.

## Release an unknown owner

An unknown owner has inconclusive process evidence, including session-only ownership.
A force release can release an owner that is still running.
The operator should check the shown process first.
Lease expiry alone does not permit release or removal.
Never offer this release for an `alive` owner.
Never release another session's owner automatically.

1. Read one snapshot of the refused worktree's owner record:

   ```bash
   source .claude/hooks/_lib-worktree-owner.sh
   OWNER_GITDIR=$(git -C "<path>" rev-parse --absolute-git-dir) || exit 1
   OWNER_RECORD=$(cat "$OWNER_GITDIR/apexyard-owner") || exit 1
   SHOWN_GENERATION=$(printf '%s\n' "$OWNER_RECORD" | jq -er '.generation | select(type == "number" and . > 0 and . == floor)') || exit 1
   printf '%s\n' "$OWNER_RECORD" | jq '{status, owner, lease_heartbeat_at, lease_expires_at, generation}'
   ```

   Show the session id, harness, PID, process start, boot identity, lease times, and generation from this snapshot.
   PID means process identifier.
   The generation is the record's revision number.
   If the record cannot be read, keep the refusal.
   A malformed record cannot be force released.
2. Ask the operator with `AskUserQuestion` whether to release this owner.
   Offer "Release this owner" and "Keep it".
   Explain that release changes ownership and does not remove the worktree.
3. The procedure permits this call only after an explicit yes:

   ```bash
   source .claude/hooks/_lib-worktree-owner.sh
   worktree_owner_force_release "<path>" <shown-generation>
   ```

   Use the generation shown in step 1 for `<shown-generation>`.
   The operator confirmation is procedural and the library does not enforce it.
   Any caller can run `worktree_owner_force_release` or edit the record directly.

   The library checks the active status and shown generation under its lock.
   It also refuses an owner that is now `alive`.
   A mismatch leaves the record bytes unchanged.
   A successful release records the caller, sets `forced: true`, and increments the generation.
4. On success, list candidates again with the same `--merged-head "<merged-head-sha>"` argument.
   Ask separately before removing an `ok` candidate.
   On failure, report the refusal.
   Do not retry with a newer generation without showing it and obtaining another explicit yes.

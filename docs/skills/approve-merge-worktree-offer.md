# /approve-merge step 9a: offer to remove the merged worktree

This is the full text of step 9a. The skill keeps a short form.

## 9a. Optional: offer to remove the merged PR's worktree

Skip this step when `MERGE_RC` is not 0, and when `--no-merge` was passed.

A merged PR often leaves a linked worktree on disk. Removing it also removes its ticket marker, because the marker lives in the worktree's git dir. Offer the removal. Never do it without a yes.

1. Find the local clone of the PR's repo, the **source tree**. For a registered project it is `workspace/<name>/`, or the `workspace:` path of its registry entry. For a PR on the ops fork it is the ops root.
2. List the candidates with the helper.
   Use the merged PR's head branch and the verified `HEAD_SHA` from step 4:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh list "<source-tree>" "<head-branch>" --merged-head "$HEAD_SHA"
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
   - The owner must be `dead`, `none`, or `released`.
   - The worktree must have no uncommitted changes.
   - Remote-tracking refs must preserve every commit, unless the merged-head rule applies.

   A remote-tracking ref is a local record of a remote branch.
   The merged-head rule accepts an unpushed `HEAD` equal to, or an ancestor of, `HEAD_SHA`.
   This rule supports squash merges followed by remote branch deletion.
   Without `--merged-head`, unpushed commits always refuse cleanup.
   A missing owner library or `jq` refuses cleanup with `owner check unavailable`.
   An inconclusive preservation check also refuses cleanup.
   For an `owner unknown` refusal, follow the release procedure below.
3. If there is an `ok` worktree, ask with `AskUserQuestion`. Show the path and the ignored files the helper listed, because `git worktree remove` deletes them. Offer "Remove it" and "Keep it".
4. On "Remove it", run:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh remove "<source-tree>" "<path>" "<head-branch>" --merged-head "$HEAD_SHA"
   ```

   The helper rechecks the branch and every refusal rule.
   It runs `git worktree remove` with no `--force`.
   A dirty worktree stops the step.
   Report the helper's message.
   Leave a refused worktree for the user.
5. On "Keep it", do nothing. Do not ask again.

Never remove a path that the helper did not list. Never pass `--force`.

## Release an unknown owner

An unknown owner has inconclusive process evidence, including session-only ownership.
Lease expiry alone does not permit release or removal.
Never offer this release for an `alive` owner.
Never release an owner automatically.

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
3. Only an explicit yes permits this call:

   ```bash
   worktree_owner_force_release "<path>" "$SHOWN_GENERATION"
   ```

   The library checks the active status and shown generation under its lock.
   It also refuses an owner that is now `alive`.
   A mismatch leaves the record bytes unchanged.
   A successful release records the caller, sets `forced: true`, and increments the generation.
4. On success, list candidates again with the same `--merged-head "$HEAD_SHA"` argument.
   Ask separately before removing an `ok` candidate.
   On failure, report the refusal.
   Do not retry with a newer generation without showing it and obtaining another explicit yes.


# /approve-merge step 9a: offer to remove the merged worktree

This is the full text of step 9a. The skill keeps a short form.

## 9a. Optional: offer to remove the merged PR's worktree

Skip this step when `MERGE_RC` is not 0, and when `--no-merge` was passed.

A merged PR often leaves a linked worktree on disk. Removing it also removes its ticket marker, because the marker lives in the worktree's git dir. Offer the removal. Never do it without a yes.

1. Find the local clone of the PR's repo, the **source tree**. For a registered project it is `workspace/<name>/`, or the `workspace:` path of its registry entry. For a PR on the ops fork it is the ops root.
2. List the candidates with the helper. The head branch is the merged PR's head branch:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh list "<source-tree>" "<head-branch>"
   ```

   The helper takes candidates only from `git worktree list --porcelain -z`, run with `-C` on the validated common dir. The `-z` option needs git 2.36 or later. With an older git, the helper lists no worktree, prints an error and removes nothing. Tell the user that the worktree stays on disk. The helper prints `ok` or `refused (<reason>)` for each worktree that holds the branch, and the ignored files of each `ok` worktree. It refuses the main worktree, a locked worktree, the session's own tree, and any path that equals or contains the ops root.
3. If there is an `ok` worktree, ask with `AskUserQuestion`. Show the path and the ignored files the helper listed, because `git worktree remove` deletes them. Offer "Remove it" and "Keep it".
4. On "Remove it", run:

   ```bash
   .claude/skills/approve-merge/remove-worktree.sh remove "<source-tree>" "<path>" "<head-branch>"
   ```

   The helper first re-checks that the worktree still holds the merged head branch and passes every refusal rule. It runs `git worktree remove` with no `--force`. A dirty worktree stops the step. Report the helper's message, and leave the worktree for the user.
5. On "Keep it", do nothing. Do not ask again.

Never remove a path that the helper did not list. Never pass `--force`.


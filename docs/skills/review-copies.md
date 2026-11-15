# Light review copies

A light review copy is a shallow, one-commit, standalone clone of one PR head. See AgDR-0305.

Run `.claude/skills/code-review/review-copy.sh create <repo-url> <repo-slug> <pr-number> <head-sha>` before step 0 arms the active-reviewer marker. The mutation lock blocks `git clone`, `git fetch` and `git checkout` after that.

- The copy sits under `<temp dir>/apexyard-review-copies/<slug>-pr<N>`.
- The record `.git/apexyard-review-copy.json` holds the repo, PR, head SHA, session and UTC creation time.
- Give the printed path to the reviewer.
- `review-copy.sh list` shows all copies. `review-copy.sh remove <path>` deletes one copy that has a record.
- Do not make a full clone for a scratch review.

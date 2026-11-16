# Light review copies

A light review copy is a shallow, one-commit, standalone clone of one PR head. See AgDR-0305.

Run `.claude/skills/code-review/review-copy.sh create <repo-url> <owner/name> <pr-number> <head-sha>` before step 0 arms the active-reviewer marker. The mutation lock blocks `git clone`, `git fetch` and `git checkout` after that.

- The copy sits under `<temp dir>/apexyard-review-copies/<owner>__<name>-pr<N>`.
- The record `.git/apexyard-review-copy.json` holds the repo, PR, head SHA, session and UTC creation time.
- Give the printed path to the reviewer.
- `review-copy.sh list` shows all copies. `review-copy.sh remove <path>` deletes one copy that has a record.
- Do not make a full clone for a scratch review.

The repo input requires exactly one slash and nonempty owner and name components.
Each component accepts letters, digits, dots, dashes and underscores.
Forks and upstream repositories use separate folders.

The JSON record contains `repo`, `pr`, `head_sha`, `session`, `created_at` and `path`.
`repo` holds `owner/name`. `pr` is a number. The other fields are strings.
`created_at` uses UTC. `path` holds the absolute copy path.
`list` reports `repo` as `unknown` for old records without an owner.

Before create, list or remove, the script checks the root.
It creates a missing root with mode 0700.
The root must be a real directory owned by the current user, without group or world write permission.
A symlink root fails the check.
Removal requires a real copy directory directly under the resolved root.

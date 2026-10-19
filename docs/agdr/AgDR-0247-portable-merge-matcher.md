# AgDR-0247: Keep the merge matcher portable and literal

> For the shared merge matcher, I chose a counted window and literal merge arguments, so old mawk can read a direct merge and the documented approve-merge call can pass the gate.

## Context

Three bugs block commands the gates must allow. They share one matcher.

- mawk 1.3.4 on Debian aborts on an ERE interval in the shell `-c` check. The fail-closed fallback then blocks every direct merge.
- `/approve-merge` step 6 passes `$PR_HOST_REPO` in the merge call. The gate reads that text before the shell expands it.
- A search pattern or a quoted heredoc body that names a merge call is treated as a merge.

The matcher fails closed. A new allow path needs a test that the matching real merge still blocks.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the interval | Short pattern | Old mawk aborts and blocks every direct merge |
| Count 200 characters in awk | Same bound on every awk | A few more lines |
| Accept `$PR_HOST_REPO` in the gate | The skill text can stay | A variable can name the wrong PR |
| Put the repo and the PR in the call as literals | The gate can read the target | The agent copies the checked values |
| Treat every quoted string as data | Fixes the search false positive | A `sh -c` script would skip the gate |
| Mask only grep patterns and inert quoted heredocs | Read-only text is allowed | An executor in the same command stays raw |

## Decision

Chosen: **count the window, require literals, and mask only inert data**, because each allow path still leaves a real merge visible.

- Replace the interval with a loop. A merge may start at most 200 characters after the `-c` quote.
- Scan awk program literals in every `.claude/hooks/_lib-*.sh` file. Do not flag a POSIX grep interval.
- In `/approve-merge` step 6, pass the repo and the PR as literals. Stop when the check script returns a different host repo.
- Blank a grep, egrep, or fgrep pattern unless a dangerous grep option is present.
- Inside a double-quoted argument of an allowlisted command, treat `$name` and `${name}` as data. `$(`, backticks, and `${` with an operator still keep the raw text.
- Strip a quoted heredoc body only when every command word is on the data list. An interpreter heredoc, a pipe to a shell, and a later executor stay visible.

## Consequences

- A literal `gh pr merge` is checked on Debian and Ubuntu.
- The documented approve-merge call is not a variable target.
- A grep for a merge call, and a quoted heredoc that only cats that text, are not merges.
- A variable merge, a `sh -c` or `bash -c` wrapper, and an argv `-c` wrapper still block.
- An uncertain command stays on the raw scan.

## Architecture evolution

### Portable window and a narrower data view (#1761)

The opaque-wrapper check used an ERE interval. Old mawk rejects that interval. The fallback then marked every direct merge as opaque. A counted window keeps the same 200-character bound without an interval.

The data view now hides a grep pattern and a quoted heredoc body when the command cannot run them. It does not hide a shell `-c` script, an interpreter heredoc, or a variable merge. The approve-merge skill places the checked repo and PR in the merge call as literals. The gate reads the command text before the shell expands it.

## Artifacts

- Issues #1757, #1758, #1760, and #1761
- `.claude/hooks/_lib-extract-pr.sh`
- `.claude/skills/approve-merge/SKILL.md`
- `.claude/hooks/tests/test_awk_ere_interval_lock.sh`
- `.claude/hooks/tests/test_merge_matcher_1761.sh`

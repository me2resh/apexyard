# Dispatch merge gates for wrapped merge commands

> In the context of Bash PreToolUse dispatch (AgDR-0157), facing a prefix `case` that skipped wrapped `tracker_pr_merge` calls, I decided to route merge gates through `is_merge_command` on the full command. This fails closed on `/approve-merge`'s `bash -c` wrapper. A non-merge command that names those words may spawn the four gates.

## Status

Accepted

## Context

Issue me2resh/apexyard#1338 reported a UI PR that merged with no design marker. Replaying the inner `tracker_pr_merge` command through `require-design-review-for-ui.sh` blocked. The live `/approve-merge` call used `bash -c` around the wrapper.

`dispatch-bash.sh` routes merge gates with a prefix `case` on `.tool_input.command`. A command that starts with `bash -c` does not match `tracker_pr_merge *`. Unconditional safety hooks still run. The four merge gates do not. Claude Code then allows the tool call.

`is_merge_command` in `_lib-extract-pr.sh` already scans the full command string. The extractors resolve a quoted `tracker_pr_merge "owner/repo" "N"` inside `bash -c`. The miss is the dispatcher route, not the gate body.

This is a trust-chain control. Parent record: AgDR-0157.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Run merge gates when `is_merge_command` matches, after the prefix `case` | Reuses the audited parser. Covers `bash -c`, sourced libs, and command substitution | A comment that names `tracker_pr_merge` spawns the four gates. They then exit 0 if the command is not a merge |
| Unwrap `bash -c` and re-dispatch the inner script | Matches one wrapper shape | Misses `bash`, `env`, sourced files, and `$(tracker_pr_merge …)` |
| Change `/approve-merge` so the Bash command starts with `tracker_pr_merge` | Restores prefix match for that skill | Any other wrapper still fail-opens. The skill documents `bash -c` for a reason |
| Widen adapter globs to `*tracker_pr_merge*` only | Helps pi and opencode | Claude Code no longer uses those globs. The dispatcher `case` stays prefix-only |

## Decision

Chosen: **run the four merge gates when `is_merge_command` matches**, because the parser already knows the merge shapes and the gate must fail closed on a wrapper.

The prefix `case` still runs the same gates for the documented one-line forms. A helper runs each merge gate at most once per payload. An empty command still takes the T13 path from AgDR-0157. If `is_merge_command` is not in scope, the dispatcher still runs the four merge gates. A `git add` or `git commit` payload that also contains a merge shape is gated. A commit message that names the wrapper token is fail-closed.

This PR does not change pi and opencode glob strings. Those adapters still derive prefix globs from the dispatcher comments. That residual is a follow-up.

## Consequences

- `bash -c 'tracker_pr_merge owner/repo 42 squash true'` runs the four merge gates on Claude Code and Cursor.
- A payload whose command text contains `tracker_pr_merge` or `gh pr merge` also runs those gates. The hook bodies still no-op or block on their own parse.
- `test_dispatch_bash.sh` must cover a `bash -c` merge payload.
- pi and opencode keep prefix globs until a follow-up widens them.

## Artifacts

- Issue: me2resh/apexyard#1338
- Parent: docs/agdr/AgDR-0157-bash-pretooluse-dispatcher.md

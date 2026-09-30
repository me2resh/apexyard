# AgDR-0205: Scope reviewer worktree add to literal paths outside governed trees

> In the context of an active review window, facing a `git worktree add` that the lock either blocked as `git add` or allowed with no checks, I decided to allow only a literal, single-line worktree add to a path outside the ops fork and the managed workspace, and to keep checking every other segment of the same command.

## Context

AgDR-0147 allowed `git worktree add` during an active review so that a reviewer can make an isolated checkout. The allow rule was one regex on the whole command:

- Forms such as `cd /tmp/scratch&&git worktree add /tmp/x <sha>`, or a worktree add followed by `&& bash run.sh`, missed the regex. The mutation list then read `worktree add` as `git add` and blocked it. Reviewers could not run tests at the PR head (#1509).
- The regex allowed any text between `git` and `worktree add`. That let through `git -c core.hooksPath=... worktree add`, which can run code on checkout, and `git worktree add /x $(git push)`, which runs a push.
- The regex allowed a path inside the ops fork or `workspace/`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Widen the whole-command regex | Small change | Any allow of a whole command lets the rest of that command through |
| Allow worktree add only before the marker is armed | No parsing during a review | Breaks the documented mid-review flow |
| Check each worktree-add segment, replace it with `true`, and keep all other checks | The documented forms work. No other segment gains an allow | Needs a segment parser and a strict segment shape |

## Decision

Chosen: **check each worktree-add segment and keep all other checks**.

- The hook splits the command on `&&`, `||`, `;`, `|` and `&`. A multi-line command with a worktree add is blocked.
- Each worktree-add segment must be a literal `git [-C <dir>] worktree add <options> <path> [<commit>]`, with no quotes, `$`, backticks, environment prefix or other git global option. Any other shape is blocked.
- The path is the first argument that is not an option. Only fully spelled options from a fixed list are accepted, and only `-b`, `-B` and `--reason` take a value. Git also reads grouped short options (`-fb`) and long-option prefixes (`--reas`), which would make the parser read the wrong word, so any other option blocks the command.
- A relative path resolves against `-C`, then the last literal `cd` in the command, then the working directory. A non-literal `cd`, or `cd -`, makes the base unknown, and a relative path is then blocked.
- The resolved path must be outside the ops fork, `<ops>/workspace`, and the configured portfolio workspace (`portfolio_workspace_dir`, split-portfolio mode).
- The hook replaces each checked segment with `true` and rebuilds the command with ` ; ` between segments. The later checks recognise `;` before `git`, but not a lone `&`, so keeping `&` would hide the next segment (review of PR #1518). All later checks, including the mutation list, read the rest of the command.

## Consequences

- A reviewer can run `cd <clone> && git worktree add /tmp/x <sha> && cd /tmp/x && bash <test>`.
- `git worktree add /tmp/x <sha> && git push` stays blocked, because the push segment is still checked.
- `-c`, environment prefixes and expansions in a worktree-add segment are blocked. `dev` allowed them.
- A worktree path under a governed tree is blocked.
- Quoted paths are blocked. Reviewers use literal paths.

## Artifacts

- Issue #1509
- AgDR-0147 (narrowed by this decision)
- `.claude/hooks/block-reviewer-repo-mutation.sh`
- `.claude/hooks/tests/test_block_reviewer_worktree_add_scope.sh`

# Rank an explicit git -C commit path above payload cwd

> In the context of `verify-commit-refs.sh` worktree resolution (me2resh/apexyard#1050, PR #1073), facing a harness `.cwd` that hid a this-commit `git -C` path, I decided to rank the message-stripped, this-invocation `-C` and `cd` scrape above payload cwd. This restores tracker lookup for worktree commits from an ops-fork session. A shared cross-hook resolver stays out of this PR.

## Status

Accepted

## Context

Issue me2resh/apexyard#1340 reproduces #1050 on current `dev` (`b768d22`) and on v5.6.2. The `-C` parser matches `git -C /abs/path commit`. Payload `.cwd` is set first when the harness sends an absolute cwd. That branch never runs in a normal Claude Code or Cursor Bash call.

`validate-commit-format.sh` blocks `cd <dir> && git commit`. Agents then use `git -C <worktree> commit` from the ops-fork session. The hook looks up the bare `#N` in the ops origin. A real issue in the managed project tracker false-blocks.

PR #1073 ranked `.cwd` first because scrape hijacks were still open. Those hijacks now have separate mitigations.

- The commit message is stripped before the scrape.
- `-C` must sit immediately before this `commit` token.
- Only absolute scraped paths are trusted.

This is a trust-chain control. Parent records: #1050 and PR #1073.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Rank this-commit `-C` and `cd` scrape above payload `.cwd` | Smallest change that matches the reported Given/When/Then. Reuses the audited parser | A decoy `-C` bound to this commit wins over a correct harness cwd |
| Keep `.cwd` first | Matches PR #1073 and current case 1b | The `-C` parser stays dead in harness sessions. #1050 returns |
| Split the scrape. Rank only `-C` above `.cwd`. Leave `cd` below it | Narrower intent signal | Splits one function for a path the format hook already blocks |
| Add a shared "which repo is this call about" resolver | Fixes the class named in #194, #1050, and #1340 | New cross-hook surface. Out of this ticket's acceptance criteria |

## Decision

Chosen: **rank the existing this-commit scrape above payload `.cwd`**, because the hijack mitigations now exist and an explicit `-C` names the commit's repository.

Payload `.cwd` stays the default when the scrape returns nothing. Process cwd stays the last fallback. This PR does not add a shared resolver. This PR does not change `validate-commit-format.sh` skip of `git -C` commits. That skip is a separate gap.

## Consequences

- `git -C <project-worktree> commit` with `.cwd` at the ops fork validates refs against the project origin.
- Case 1b in `test_verify_commit_refs_cwd.sh` must flip. A this-commit `-C` now outranks `.cwd`.
- A new case must pin the reporter shape. Payload cwd is the ops fork. `-C` is the project. The issue exists only in the project.
- Agents can keep bare `Closes #N` on worktree commits. They should not switch to a URL or `owner/repo#N` to dodge the gate.

## Artifacts

- Issue: me2resh/apexyard#1340
- Parent: me2resh/apexyard#1050
- Tests: `.claude/hooks/tests/test_verify_commit_refs_cwd.sh`

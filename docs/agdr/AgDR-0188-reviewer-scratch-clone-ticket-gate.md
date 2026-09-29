# Allow Review Tests in Temporary Clones

> In the context of a sanctioned PR review, I allow fixture writes in temporary standalone clones. The ticket gate still protects governed paths.

## Context

Reviewers run tests against scratch copies of a PR. The ticket gate blocks writes inside a scratch git clone without an active ticket.

The existing non-git export exemption already permits fixture writes outside governed paths. The reviewer agents already instruct reviewers to report blocked commands.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Use only non-git exports | Uses the existing exemption | Prevents tests that need git metadata |
| Allow temporary standalone clones during a sanctioned review | Supports clone-based tests without a ticket | Adds a narrow exception to the ticket gate |

## Decision

Chosen: **allow temporary standalone clones during a sanctioned review**. The hook requires a session-scoped marker for Rex, Security, or Architecture review.

The hook checks that the target belongs to a standalone git repository with an origin remote under a temporary directory. It rejects linked worktrees and path traversal.

The hook checks raw and resolved targets against the ops fork and managed workspace. It checks every Bash write target separately. Any symlink in a target path, including a dangling final-component link, prevents the exemption.

The hook compares the active marker's ops root with the hook's own ops root. Missing or mismatched context keeps the ticket gate active.

When the session pin is disabled, the hook uses Claude Code's ops-fork working directory to replace a scratch clone's misleading root only when it matches the hook's anchored root. The exception requires that working-directory match even with a pin, so unresolved or symlink-spoofed roots stay gated.

## Consequences

- A sanctioned reviewer can create test fixtures in a temporary scratch clone without a ticket.
- Writes into the ops fork and managed workspace still require a ticket.
- Symlinked targets never receive the scratch-clone or non-git export exemption.
- A `git worktree add` checkout is a linked worktree. Writes there still require a ticket.
- Clones outside temporary directories still require a ticket.
- Temporary repositories without an origin remote still require a ticket.
- The marker identifies the reviewing session. It does not identify an individual process within that session.

## Artifacts

- Issue #1402
- `.claude/hooks/require-active-ticket.sh`
- `.claude/hooks/tests/test_require_active_ticket_review_scratch.sh`

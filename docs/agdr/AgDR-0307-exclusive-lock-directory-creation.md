# Exclusive lock directory creation

> Facing non-atomic mkdir behavior, we chose an exclusive file guard to serialize lock directory creation, accepting manual recovery for abandoned guards.

## Context

Issue #2097 and PR #2099 concern lost progress-note entries during concurrent writes.
The operator reports that Ubuntu 26.04 uutils mkdir 0.10.0 can report success to two concurrent creators.
Both progress-note and worktree-owner libraries previously treated mkdir success as exclusive ownership.
Existing readers inspect lock directories and the worktree-owner identity file.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Replace lock directories with files | Bash noclobber provides exclusive creation. | Changes owner publication and existing directory readers. |
| Guard directory creation with an exclusive file | Preserves lock directories and owner recovery. | Adds a temporary guard path. |
| Require GNU mkdir | Preserves current code. | Adds a platform dependency. |

## Decision

Use a shared directory-creation helper because it preserves existing lock paths, readers, and owner identity checks.
Bash noclobber creates a sibling `.creating` file with exclusive creation semantics.
Only its holder checks directory existence and invokes mkdir.
The helper refuses existing directories and symbolic links, regardless of mkdir behavior.
The helper removes its guard on normal exit, failure, and handled signals.
Both libraries use the helper, including the worktree-owner reaping guard.

## Consequences

Progress-note contention still fails immediately.
Worktree-owner contention retains six attempts and its existing delays.
Worktree-owner stale-lock recovery still requires a proven dead identity and an unchanged owner record.
An unhandled termination can leave a creation guard requiring operator attention.
An existing creation guard never authorizes takeover or deletion.
Fixture copies must include the shared helper.

## Artifacts

- Issue: me2resh/apexyard#2097.
- PR: me2resh/apexyard#2099.
- Regression: `.claude/hooks/tests/test_non_atomic_mkdir_lock.sh`.
- The regression uses FIFO synchronization and a fake mkdir without sleeps or retries.

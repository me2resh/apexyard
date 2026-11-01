# AgDR-0284: Record worktree owners in the worktree git dir

## Context

Issue #1940 requires worktrees to identify their owners.
Ticket and session markers identify work, but they do not check whether a worktree's writer still runs.
Concurrent sessions need a shared record before lifecycle commands can safely inspect, renew, or release ownership.

## Options Considered

### Record location

| Option | Benefit | Cost |
|--------|---------|------|
| Store records beneath the ops root | Central directory for readers | Adds a storage tier, ignore rules, and separate cleanup |
| Store records beside the ticket marker in the worktree git dir | Reuses Git cleanup | Requires linked worktree metadata checks |
| Keep no owner record | Adds no state | Cannot distinguish ownership from ticket assignment |

### Owner identity

| Option | Benefit | Cost |
|--------|---------|------|
| Process identity only | Supports process checks | Short helper processes cannot identify the owning session |
| Session identity only | Works across harnesses | Cannot prove that a writer still runs |
| Session identity with optional harness process identity | Preserves session ownership and permits verified process checks | Requires conservative handling when process evidence is unavailable |

## Decision

> Record each worktree's owner and lease beside its ticket marker. Combine session identity with optional verified harness process identity.

Use `.claude/hooks/_lib-worktree-owner.sh` for identity, acquisition, renewal, release, and status.
Store the JSON record as `apexyard-owner` in the validated worktree git dir.
Resolve the git dir through Git's read-only metadata commands.
Refuse main working trees, non-repositories, and symlinked git dirs, records, or locks.

Resolve `CLAUDE_CODE_SESSION_ID` first, then `APEXYARD_SESSION_ID`, following AgDR-0250.
Keep the session identity empty when both variables are empty.
Do not invent a shared session identity.
Record a harness process only when ancestor inspection identifies a supported harness.
Do not record the short shell helper as the harness owner.

Use process start time and boot identity to detect reused process identifiers.
Read process start times in UTC. On macOS, retain the numeric `sec` and `usec` fields of `kern.boottime` and discard its formatted date suffix.
Read Linux boot identity from `/proc/sys/kernel/random/boot_id`.
Read macOS boot identity through `sysctl -n kern.boottime`.
Use `kill -0` and `ps` for process checks.
A denied signal does not prove death.
Check process visibility through `ps` before classifying a denied signal.
Missing or inconclusive process evidence produces `unknown` liveness, never `dead`.

Protect record writes with a directory lock.
The lock records the process that runs the critical section, not its parent shell.
Before invoking deletion, a reaper checks that the recorded identity matches the identity it proved dead.
That check and the deletion are not atomic.
The delayed-unlock schedule in Consequences can still cause deletion of a newer lock.
Publish the lock owner through a temporary file in the lock directory and a rename.
Readers then see either no owner or a complete line.
Replace the record atomically after writing a temporary file beside it.
Increment the generation on every successful acquisition, renewal, or release write.
Under the delayed-unlock schedule in Consequences, writers can overlap and a generation increment can be lost.
An expired lease indicates a missed renewal.
Lease expiry never proves process death and never permits automatic takeover.

The preparation helper acquires ownership after writing the ticket markers.
If acquisition fails, it attempts to remove the worktree and the branch it created.
It preserves the existing fallback for worktrees whose git dirs fail validation and reports the missing owner record.

## Consequences

Only the Claude Code process matcher ships with this change.
Other harnesses retain session-only ownership records.
An active session-only owner's liveness remains `unknown` until explicit release.
Later lifecycle commands must preserve that uncertainty when they decide whether a worktree can be removed.
Two callers with no session id and no harness match have equal identities.
Either caller can renew or release a record that the other acquired.

Git removes the owner record when it removes the worktree's administrative directory.
Records require no additional ignore rules or separate state directory.
The preparation helper now requires `jq` through the owner library.
Directory locks and validated paths coordinate cooperating processes.
They do not prevent a user with filesystem write access from modifying records directly.

While a guarded lock directory remains in place, the guard prevents another reaper from acquiring it.
If the holder or the reaper dies and no pending deletion removes the directory, later ownership writes refuse.
This PR has no recovery command.
A later lifecycle PR can add one.

Unlock and reaping remove the lock directory with an external `rm -rf`.
That command can pause and outlive the process that started it.
This delayed-unlock schedule defeats the lock:

1. A holder starts an external unlock `rm -rf`, which pauses and survives the holder's death.
2. A reaper verifies the dead holder, creates its `reaping` guard, and rechecks the recorded identity successfully.
3. Before the reaper's deletion executes, the old unlock resumes and removes the directory, including the guard.
4. A new caller acquires the lock at the same path.
5. The reaper's deletion then removes that newer lock.

This implementation cannot exclude this schedule.
Under it, mutual exclusion can fail.
Writers may then overlap, generation increments may be lost, and ownership checks may use stale records.
A lock built from directories and external commands cannot exclude it.
A kernel-backed lock could, at the cost of a new dependency.

## Artifacts

- Refs #1940
- `.claude/hooks/_lib-worktree-owner.sh`
- `.claude/hooks/tests/test_lib_worktree_owner.sh`
- `.claude/hooks/tests/test_fan_out_marker.sh`
- `.claude/skills/fan-out/prepare-worktree.sh`
- `.claude/skills/fan-out/SKILL.md`

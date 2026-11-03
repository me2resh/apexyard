# AgDR-0284: Record worktree owners in the worktree git dir

## Decision

Record each worktree's owner and lease beside its ticket marker. Combine session identity with optional verified harness process identity.
Issue #1940 needs ownership evidence for concurrent lifecycle commands. Ticket and session markers alone cannot prove that a writer still runs.

## Design

- Use `.claude/hooks/_lib-worktree-owner.sh` for identity, acquisition, renewal, release, and status.
- Store JSON as `apexyard-owner` in the validated worktree git dir. Resolve that directory through Git's read-only metadata commands.
- Refuse main working trees, non-repositories, and symlinked git dirs, records, or locks. Refuse newline or tab paths to prevent command-substitution collisions.
- Resolve `CLAUDE_CODE_SESSION_ID` before `APEXYARD_SESSION_ID`, following AgDR-0250. Preserve an empty identity when both variables are empty. Never invent a shared identity.
- Record a process only when ancestor inspection identifies a supported harness. Never substitute the short shell helper for the harness owner.
- Detect reused process identifiers through process start time and boot identity. Read start times in UTC and prefix start text with `UTC` followed by a space.
- Read Linux boot identity from `/proc/sys/kernel/random/boot_id`. On macOS, use `sysctl -n kern.boottime` and retain numeric `sec` and `usec` fields without the formatted date suffix.
- Use `kill -0` and `ps`. A denied signal requires a visibility check through `ps` and never proves death alone.
- Check process absence and boot identity before start evidence. Require the `UTC` plus `lstart` shape. Unrecognised start text or inconclusive evidence yields `unknown`.
- Protect writes with a directory lock. Record the process executing the critical section, not its parent shell.
- Publish the lock owner through a temporary file and rename within the lock directory. Readers see either no owner or a complete line.
- Before deletion, reapers require the recorded identity to match the exact identity proved dead. The check and deletion remain non-atomic.
- Replace records atomically through a temporary file beside the record. Increment the generation after each successful acquisition, renewal, or release write.
- Lease expiry indicates a missed renewal. It never proves process death or permits automatic takeover.
- Fan-out preparation acquires ownership after writing ticket markers. On acquisition failure, the helper attempts to remove its newly created worktree and branch.
- Preserve the existing fallback when worktree git dirs fail validation. Report the missing owner record.

## Alternatives

| Alternative | Benefit | Cost |
|-------------|---------|------|
| Ops-root records | Central reader directory | Adds storage, ignore rules, and separate cleanup |
| Git-dir records (chosen) | Reuses Git cleanup | Requires linked worktree metadata checks |
| No owner record | Adds no state | Cannot distinguish ownership from ticket assignment |
| Process identity only | Supports process checks | Short helpers cannot identify the owning session |
| Session identity only | Works across harnesses | Cannot prove that a writer still runs |
| Session with optional harness identity (chosen) | Preserves session ownership and verified process checks | Requires conservative handling of unavailable evidence |

## Residual risks

- Only the Claude Code process matcher ships. Other harnesses retain session-only records, whose liveness remains `unknown` until explicit release.
- Later lifecycle commands must preserve that uncertainty when deciding whether to remove worktrees.
- Callers without session ids or harness matches have equal identities. Either caller can renew or release the other's record.
- Git removes records with the worktree administrative directory. No extra ignore rules or separate state directory are needed.
- The preparation helper now requires `jq` through the library. Locks and validated paths coordinate cooperating processes but cannot prevent direct filesystem modifications.
- A `reaping` guard prevents another reaper from acquiring the guarded directory. Holder or reaper death can strand it unless pending deletion removes it.
- A stranded guard makes later ownership writes refuse. This change provides no recovery command. A later lifecycle change can add one.

Unlock and reaping use external `rm -rf`, which can pause and outlive its initiating process. This delayed-unlock schedule defeats the lock:

1. A holder starts an unlock deletion, which pauses and survives the holder's death.
2. A reaper proves the holder dead, creates its `reaping` guard, and successfully rechecks the recorded identity.
3. The old unlock resumes before reaper deletion and removes the directory, including the guard.
4. A new caller acquires the lock at the same path.
5. The reaper's delayed deletion removes the newer lock.

Directory locks with external commands cannot exclude this schedule. Mutual exclusion can fail, writers can overlap, generation increments can disappear, and ownership checks can use stale records.
A kernel-backed lock could exclude it, at the cost of a new dependency.

Implementation artifacts include `.claude/hooks/_lib-worktree-owner.sh`, `.claude/skills/fan-out/prepare-worktree.sh`, and `.claude/skills/fan-out/SKILL.md`.
Regression coverage lives in `.claude/hooks/tests/test_lib_worktree_owner.sh` and `.claude/hooks/tests/test_fan_out_marker.sh`.

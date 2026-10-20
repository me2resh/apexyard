---
id: AgDR-0257
timestamp: 2026-10-19T12:00:00Z
agent: composer
model: composer
session: feat-1533
trigger: user-prompt
status: executed
category: patterns
---

# Ticket marker session and branch warning

> In the context of two sessions that share one clone, facing a silent last-writer-wins ticket marker, I decided to record `session_id` and `branch` on the marker, ask before a foreign overwrite, and warn once per session on a mismatch, to make the wrong-ticket path visible, accepting that the mismatch never blocks an edit.

## Context

Issue #1533. Two sessions in the same clone overwrite `apexyard-ticket` (and the old-layout marker) with no message. The ticket gate then allows edits against the wrong ticket. A marker can also outlive its branch after a merge or a checkout. AgDR-0066 and AgDR-0222 place one marker per working tree. They do not detect a cross-session overwrite inside one tree. AgDR-0250 keys exemption markers on the session id (`CLAUDE_CODE_SESSION_ID`, else `APEXYARD_SESSION_ID`). This decision reuses that identity for ticket-marker provenance and for once-per-session warn state.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Warn only (chosen) | Visible at edit time; exit codes stay the same; no new lock | Does not prevent the collision |
| Block on mismatch | Hard stop | Breaks legitimate take-over and headless refresh; weakens adoption |
| File lock on the marker | Serialises writers | Does not model two tickets at once; adds stale-lock cost |

## Decision

Chosen: **warn only**, because the issue asks for a visible warning and keeps the gate exit code unchanged.

1. `/start-ticket` writers add `session_id=` and `branch=` with `printf '%s\n'`. A value that holds `\n` or `\r` is rejected. The title is flattened to one line before the write. Every reader takes the first match of each key.
2. Before a write that would replace a different ticket from a different session (empty or missing `session_id` counts as different), `/start-ticket` asks: stay in a worktree that already holds your ticket (see #1534), take over, or cancel. When no answer is possible, cancel and leave the marker unchanged. `APEXYARD_START_TICKET_TAKEOVER=1` is a **cooperative signal**, not an operator gate: the skill sets it **inline** on the single write that follows the operator's take-over answer; it must never be exported and never inherited. Headless and `/fan-out` runs must not set it. No hook inspects the flag. A child Bash process cannot tell an inline prefix from an exported/inherited value (`declare -x` looks the same either way), so the writer does not attempt that distinction. Residual (same as before this PR): an agent can still set the flag, set its session id to match the marker, or edit the marker file directly. On each take-over that replaces another session's marker **and whose write succeeds**, the writer prints one stderr audit line: `apexyard: ticket marker taken over: <old ticket> (session <old id>) -> <new ticket> (session <new id>)`. Every printed field has bytes below 0x20 and 0x7f stripped.
3. `require-active-ticket.sh` and `require-migration-ticket.sh` warn on stderr when the governing marker's `session_id` or `branch` differs from the current session or tree branch. The warning names the ticket, the other session id, the marker age, and the fix. It prints once per session per marker identity (path + `session_id` + `repo` + `number` + `started_at`), so a later foreign marker at the same path still warns. The claim file name is a pure-bash hash of that identity string, so a long marker path cannot break the claim write past `NAME_MAX` and the edit path adds no `cksum`/`awk`/`tr` (#1808). When the current branch cannot be determined, skip the branch check and do not consume a claim. Warn state lives under `.claude/session/ticket-marker-warn.<safe_sid>/`. One session cannot write a path that suppresses another session's warning. No `gh` call is added to the ticket gate. The foreign-overwrite guard covers the per-tree marker, and the old-layout path only when the tree fails validation (a valid tree writes its own per-tree marker).

## Consequences

- Cross-session overwrite becomes a question or a cancel, not a silent clobber.
- A stale branch or foreign session still allows the edit; the operator sees the warning.
- Old markers without `session_id` count as foreign when a session with an id starts a different ticket.
- Separate worktrees remain the real fix for concurrent tickets (#1531, #1534).
- The take-over flag remains cooperative. The audit line makes an unexpected take-over visible on stderr. An exported flag in a parent environment would still honour take-over, because Bash cannot distinguish it from an inline prefix.

## Architecture evolution

### Before

`/start-ticket` wrote the old-layout marker
(`.claude/session/tickets/<project>`, `tickets/<project>/<branch>`,
`current-ticket`) with six keys only:
`repo`, `number`, `title`, `url`, `suggested_branch`, `started_at`.
`test_dev_compat_rows.sh` B8 and B9 pinned that exact key list so a
rollback still saw a marker the old hooks could read (AgDR-0066 /
AgDR-0222 transition).

### After

The same writers also put `session_id=` and `branch=` on the old-layout
marker, in the same order as the per-tree `apexyard-ticket` file.
Rollback safety rests on the old readers at `c40c4c79^` (before
AgDR-0222), not on today's `active_ticket_read_field`. Those readers
use anchored exact keys and take the first match: `block-ambient-tracker-repo.sh`
(`sed -n 's/^repo=//p' | head -1`), `require-migration-ticket.sh`
(`grep -E '^repo='` / `'^number='` with `head -1`), `status/briefing.sh`
`read_marker_field` (exact key, first match), and the AgDR hooks
(`^title=\[(Spike|Prototype)\]`). `require-active-ticket.sh` only
checks that the marker file exists. No old reader reads `session_id`
or `branch`, or checks key count or key order, so an unknown key has
no effect on an old hook. Keeping the new keys in the old-layout file
keeps one write path and lets a governing old-layout marker still feed
the warn path. The compat test now pins every old key and its value,
and accepts `session_id` and `branch` in that fixed order.

### Rex findings on PR #1794 (2026-10-19)

Three correctness faults in the first warn path, all fixed on this
branch:

1. The once-per-session claim was named after the marker path only. A
   second foreign marker at the same path produced no warning. The
   claim now includes `session_id`, `repo`, `number`, and `started_at`.
2. An empty current branch (migration path under a not-yet-existing
   directory, or empty `AT_TREE` for an old-layout-only tree) was
   reported as "another branch" and consumed the claim. The warn
   helper now skips the branch check when the branch is unknown. The
   migration gate resolves the tree from the nearest existing ancestor.
3. `active_ticket_foreign_overwrite` checked only the per-tree
   `apexyard-ticket`. A headless `/start-ticket` could replace another
   session's old-layout `current-ticket` / `tickets/<project>`. The
   guard now checks the old-layout path when the tree fails validation
   (the write then replaces only that file).

### Take-over honesty (Hakim A1 / CEO 2026-10-19)

The PR body once implied the take-over flag was an operator-only gate.
Hakim A1 showed it is a plain environment variable with no hook check.
CEO decision: keep the flag, document it as a cooperative signal set
inline on the take-over write only, and print one stderr audit line when
a foreign marker is replaced. Do not fake an inline-vs-inherited check:
Bash exposes both the same way to the child.

### Hakim A2 / A4 (CEO 2026-10-19, fix before merge)

A2: the audit line printed before the writers ran, so a refused write
still said "taken over", and raw control characters in a field reached
stderr. The line now prints only after a successful write, and every
printed field drops bytes below 0x20 and 0x7f.

A4: in the ops fork every tree shares `current-ticket`. A headless
`/start-ticket` in a fresh valid linked worktree with no per-tree
marker cancelled when another session held a different ticket in that
shared file, and the message told the user to use a separate worktree
they were already in. The old-layout foreign check now runs only when
the tree fails validation. A valid worktree writes its own per-tree
marker. Cancel and warn copy say "stay in a worktree that already
holds your ticket", not "use a separate worktree".

### Claim file name length (#1808 / Rex probe, 2026-10-19)

After A4/A2 the claim file was still named from the sanitised identity
string itself (marker path plus fields). Past the 255-byte name limit
the claim write failed, so every edit printed the warning again. The
claim file is now named by a pure-bash hash of the same identity
string, still under the session warn directory. A first cut used POSIX
`cksum` plus `awk` and `tr`; that pushed the per-edit process budget
over the Linux CI caps, so the hash moved into `_at_claim_hash` with
no fork. Two different identities still get two different claims; a
path longer than 200 characters warns once per session. The A2
control-character strip (`_at_strip_controls`) is also pure bash for
the same budget scan. AC fail-before pins literal SHA `d970c194`
(pre-#1794) and the claim-name fail-before pins `5734e29` (A4/A2
head), not `upstream/dev`, so the probes still fail-before after merge
(rule 10a).

## Artifacts

- Issue: me2resh/apexyard#1533 (follow-up me2resh/apexyard#1808)
- Files: `.claude/hooks/_lib-active-ticket.sh`, `.claude/hooks/require-active-ticket.sh`, `.claude/hooks/require-migration-ticket.sh`, `.claude/skills/start-ticket/SKILL.md`, `.claude/hooks/tests/test_ticket_marker_session_branch_warn_ac*.sh`, `.claude/hooks/tests/test_ticket_marker_session_branch_warn_claim_name.sh`, `.claude/hooks/tests/test_dev_compat_rows.sh`

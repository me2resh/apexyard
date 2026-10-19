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
2. Before a write that would replace a different ticket from a different session (empty or missing `session_id` counts as different), `/start-ticket` asks: separate worktree (see #1534), take over, or cancel. When no answer is possible, cancel and leave the marker unchanged. `APEXYARD_START_TICKET_TAKEOVER=1` is the mechanical take-over flag.
3. `require-active-ticket.sh` and `require-migration-ticket.sh` warn on stderr when the governing marker's `session_id` or `branch` differs from the current session or tree branch. The warning names the ticket, the other session id, the marker age, and the fix. It prints once per session per marker. Warn state lives under `.claude/session/ticket-marker-warn.<safe_sid>/`. One session cannot write a path that suppresses another session's warning. No `gh` call is added to the ticket gate.

## Consequences

- Cross-session overwrite becomes a question or a cancel, not a silent clobber.
- A stale branch or foreign session still allows the edit; the operator sees the warning.
- Old markers without `session_id` count as foreign when a session with an id starts a different ticket.
- Separate worktrees remain the real fix for concurrent tickets (#1531, #1534).

## Artifacts

- Issue: me2resh/apexyard#1533
- Files: `.claude/hooks/_lib-active-ticket.sh`, `.claude/hooks/require-active-ticket.sh`, `.claude/hooks/require-migration-ticket.sh`, `.claude/skills/start-ticket/SKILL.md`, `.claude/hooks/tests/test_ticket_marker_session_branch_warn_ac*.sh`

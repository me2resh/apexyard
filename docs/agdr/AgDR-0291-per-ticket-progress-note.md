---
id: AgDR-0291
timestamp: 2026-11-08T12:00:00Z
agent: claude
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# A per-ticket progress note and a checkable done condition

> In the context of long agent sessions that lose their place at compaction or at a new session, facing a resume that depends on a summary of the conversation, we decided to keep one fixed-field progress note per ticket worktree, print it at SessionStart, and state a `/goal` done condition at `/start-ticket`, and neglected a tracked progress file or a gate that reads the note, to achieve a resume from saved state, accepting that the note is advisory and that its text can carry untrusted content into later sessions.

## Context

- On 8 Nov 2026 a long session continued from a compaction summary. Decisions, open issues and the next step lived only in the conversation.
- Issue #1991 asks for one progress note per active ticket, shown at SessionStart and after compaction, plus a done condition stated as evidence.
- Gate hardening is frozen (AgDR-0267). The note must not become a gate input.
- The active-ticket marker already lives in each worktree's git dir (#1534).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) A tracked `progress.md` in the working tree | Visible in the repo. | It can land in a commit. Two worktrees on one repo collide. |
| (b) A note in the worktree's git dir, next to the active-ticket marker | Never committed. One per worktree. The same lookup as the marker. | Not visible in a file browser. |
| (c) Make the note a gate input | Forces updates. | Changes gate decisions, which AgDR-0267 freezes. |

## Decision

Option (b).

- `_lib-progress-note.sh` keeps `apexyard-progress.md` in the worktree's git dir with six fixed fields: Task, Outputs, Completed, Decisions, Open issues and Next action.
- Writes use a lock directory, a temp file and a rename. The library refuses a symlinked note or marker and a note that names another ticket.
- `bin/apexyard-start-ticket` creates the note after it sets the ticket. A failure only warns, because the ticket is already set.
- A new SessionStart hook, `print-progress-note.sh`, prints the six fields on startup and after compaction, with the note's age. It warns after 24 hours. It cannot fail the dispatcher.
- `/start-ticket` tells the agent to set a `/goal` done condition: the ticket's acceptance criteria plus PR open, CI green on the head, reviewer approved at that head, and the note current, with a 20-turn limit.
- No gate hook reads the note.

## Consequences

- A new session or a compacted one sees where the ticket stands without the conversation.
- The note is advisory. The orchestrator must update it at each stage; nothing enforces that.
- The note can hold text from PRs, CI and reviews. SessionStart shows it to the next session, so text planted in a PR can reach a later session. The docs tell agents to treat the note as data, not instructions.
- A lock directory left by a killed writer blocks updates until someone removes it. The docs give the recovery step.

## Artifacts

- Ticket: me2resh/apexyard#1991
- PR: me2resh/apexyard#2004

---
id: AgDR-0168
timestamp: 2026-09-26T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: security
---

# Unextractable Bash write target honors only the session ticket

> The ticket-gate hook `require-active-ticket.sh` blocked an unextractable Bash write target, even with an active ticket. I decided to check only the ops-level `current-ticket` marker for that target, skipping the per-worktree and per-project tiers. An active session ticket now gates the write. No new exemption exists. The target still cannot use a per-project or per-worktree marker, because it carries no project to resolve them against.

## Context

`active_ticket_marker_for_path` (in `_lib-active-ticket.sh`) resolves the
marker that governs a write target. For a target the Bash-write detector
could not parse (`bash_extract_write_targets` returns empty), the function
received an empty path and returned an empty marker immediately, before it
ever checked the session's `current-ticket` fallback. The gate then blocked
the write, even with an active ticket declared, contradicting the hook's own
header comment that an unextractable target "falls through to the ticket
gate" rather than being exempted outright.

Two concrete unextractable-target commands hit this: a `sed -i` on a path
held in a shell variable, and a `git archive | tar -x` export into a scratch
directory (me2resh/apexyard#1396, me2resh/apexyard#1402).

Commit `56aacc0` (#1231) moved this marker lookup into the shared library
and added the early return that caused the regression. Before that
refactor, an empty target still reached `current-ticket`. This fix
restores that earlier behavior. It does not widen the gate.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Exempt an unextractable target from the gate entirely | Simplest change | Widens a security gate — any write the detector cannot parse would bypass the ticket requirement, reopening the class of bypass #151 closed |
| Skip only the per-worktree/per-project tiers, and still check `current-ticket` | Matches the header comment's stated intent; no new exemption; an unextractable target still needs an active session ticket | The target still cannot bind to a specific project's marker — a session with only a per-project marker (no `current-ticket`) still blocks an unextractable target for that project |
| Block unextractable targets with no fallback at all (status quo) | No behavior change | Contradicts the hook's documented intent; blocks a session that already declared a ticket, forcing an operator to fall back to Edit/Write tools for a legitimate Bash write |

## Decision

Chosen: **skip only the per-worktree/per-project tiers, and still check
`current-ticket`**, because it is the minimal change that restores the
hook's documented behavior — an active session ticket still gates the
write — without adding a new exemption path. The write is never exempted;
it is gated against whichever ticket the session actually has active.

## Consequences

- An unextractable Bash write target now honors the session's
  `current-ticket` marker, closing the false-block reported in
  me2resh/apexyard#1396.
- A per-worktree or per-project-only marker (no `current-ticket`) still
  does not satisfy an unextractable target, because the target carries no
  project to resolve those tiers against. A session working only inside a
  registered project, with no ops-level ticket set, still blocks an
  unextractable write for that project — this is unchanged and intentional.
- `require-migration-ticket.sh` shares the same library function, but it
  never sends a fully empty target. The gate exits before the library
  runs whenever it cannot extract any target at all.
- A tilde-spelled migration target (`~user/`, `~+/`, `~-/`) is a
  different case. It stays a non-empty string through normalisation. The
  resolver returns an empty path for it. An earlier commit in this PR let
  that case fall through to the ops-level `current-ticket` marker. That
  marker could approve a write meant for a different project
  (me2resh/apexyard#1159's wrong-ticket approval). Hakim's security
  review on PR #1404 flagged this as finding H1. A follow-up commit in
  this PR restores the fail-closed behavior. The function now returns an
  empty marker when a non-empty target fails to resolve.

## Artifacts

- me2resh/apexyard#1396 — the reported bug
- me2resh/apexyard#1402 — the reviewer scratch-clone follow-on this fix
  unblocks
- `.claude/hooks/_lib-active-ticket.sh` — the changed function
- `.claude/hooks/tests/test_require_active_ticket_bash.sh` — regression
  cases 79-82
- `.claude/hooks/tests/test_require_migration_ticket.sh` — the inverted-
  fixture regression cases added for finding H1

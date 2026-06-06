# Per-worktree ticket marker tier (same-project concurrent agents)

> In the context of orchestrators fanning out parallel sub-agents on the SAME managed project, facing a last-writer-wins collision on the shared per-project marker (`tickets/<project>`) that silently passes the ticket gate against the wrong ticket, I decided to add a per-worktree marker tier (`tickets/<project>/<safe-branch>`) resolved before the per-project tier, to achieve independent per-agent ticket declarations, accepting that `tickets/<project>` is now a file in single-agent mode and a directory in worktree mode (disambiguated by the hook's `-f` test).

## Context

The two-tier layout from #41 (`tickets/<project>` → `current-ticket`) fixes *cross-project* concurrency cleanly. It does **not** fix *same-project* concurrency: two agents fanned out on different tickets within one repo both write `tickets/<project>`; last writer wins, and the loser's subsequent hook checks pass against the wrong ticket — silently, no error. This blocks orchestrator throughput (the only workaround is serialising tickets per project). Confirmed real in `require-active-ticket.sh` and mirrored in `require-migration-ticket.sh`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Per-worktree tier `tickets/<project>/<branch>` (chosen) | Additive, zero change for single-agent; branch names are already unique per worktree and visible to all parties; aligns with the existing `isolation: worktree` agent model; no locking | `tickets/<project>` is file-or-dir depending on mode (handled by `-f`) |
| File-lock (flock) on the per-project marker | Keeps one path | Adds lock/timeout/stale-cleanup logic; latency; doesn't model "two tickets at once", just serialises |
| Session-per-agent (namespace by `CLAUDE_CODE_SESSION_ID`) | Minimal hook change | Breaks the cross-agent "what's everyone working on" view; markers don't survive session restarts |

## Decision

Chosen: **add tier 0** — `tickets/<project>/<safe-branch>` (`safe-branch` = branch with `/`→`__`), resolved BEFORE the per-project tier, in both `require-active-ticket.sh` and `require-migration-ticket.sh`. Branch is read from `CLAUDE_WORKTREE_BRANCH` (harness-set at spawn) or `git -C <file-dir> branch --show-current`. `/start-ticket` writes the per-worktree path when it detects a linked worktree (`--git-dir` ≠ `--git-common-dir`), else the per-project file. Single-agent / non-worktree flows detect no branch-scoped marker and fall straight through — **no behaviour change**.

The file-vs-directory duality of `tickets/<project>` is safe because every lookup uses `[ -f ]` (regular file): a directory at that path reads as "tier-1 absent", so tiers 0 and 1 never conflict in the read path. The write path (`/start-ticket`) documents removing a stale file before switching a project into worktree mode.

## Consequences

- Orchestrators can fan out independent tickets to parallel sub-agents on one repo without marker collision.
- New test cases (15/15 in `test_require_active_ticket_bash.sh`): worktree marker honored on matching branch, branch-B isolation (not satisfied by branch-A's marker), per-project file still works.
- Docs updated: hooks header comment, `.claude/hooks/README.md` (diagram + description), `/start-ticket` SKILL (layout table + write logic).
- Orphaned per-worktree markers after a worktree is removed are acceptable (same stale-marker behaviour as today).

## Artifacts

- Issue: me2resh/apexyard#513
- Files: `.claude/hooks/require-active-ticket.sh`, `.claude/hooks/require-migration-ticket.sh`, `.claude/skills/start-ticket/SKILL.md`, `.claude/hooks/README.md`, `.claude/hooks/tests/test_require_active_ticket_bash.sh`
- Builds on #41 (two-tier per-project layout)

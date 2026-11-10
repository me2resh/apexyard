# AgDR-0293: Record base health at ticket start

## Context

Ticket #2017 requires a check result for the unchanged starting commit.
The ticket note already stores evidence in each worktree's git directory.
Local edits must not affect the base result.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Run in the current tree | No extra checkout | Local edits can affect the result |
| Run in a detached worktree | Checks read the starting commit | Needs checkout space and cleanup |

## Decision

Run the configured command in a temporary detached worktree.
Use the existing ticket note to store the base SHA and result.
Reuse the result for a repeated start of the same ticket.
Use a command process group to stop all checks at the time limit.
Use `python3` to enforce that limit.
Keep `warn` as the default mode.
Apply `refuse` only when the operator configures it.

## Consequences

Each check starts from committed files.
The command must prepare any dependencies it needs.
The runner removes its worktree when it exits.
A missing command records `not configured`.
An empty repository records `unborn` as its base SHA.
A named failure uses the first `FAIL <name>` or `FAIL: <name>` line.
If no such line exists, the runner records the command as the check name.
The local framework config remains ignored by version control.

## Artifacts

- `.claude/hooks/_lib-baseline.sh`
- `.claude/hooks/tests/test_baseline.sh`
- `.claude/skills/start-ticket/SKILL.md`

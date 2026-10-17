# AgDR-0241: v5.8.0 to v5.9.0 migration is a report-only no-op

> In the context of the v5.9.0 release (#1728), facing the need for a walkable `/update` migration chain, I decided to ship a report-only `v5.8.0-to-v5.9.0.sh` that writes no file, to achieve an unbroken chain for adopters, accepting one small script per release.

**Migration type**: data (framework config, report only)
**Affected tables / entities**: none. The script writes nothing.
**Estimated downtime**: none. The script only prints messages.
**Data volume**: none. The script reads no adopter file.
**Target environment(s)**: adopter forks, during `/update`

## Context

`/update` walks `.claude/migrations/` from the fork's version to the target version. The walk stops at a missing link, so a release without a script breaks the chain for every adopter who later upgrades across it (`_lib-migration-chain.sh`).

v5.9.0 moves no adopter file. Two changes still matter to adopters:

- `/start-ticket` now writes a second marker into the git dir. Each linked worktree needs its own `/start-ticket` (#1576).
- The dispatcher and the ticket gate are fail-closed. They need Claude Code 2.1.295 or later for `onFailure` (#1623).

## Options Considered

| Option | Result |
|--------|--------|
| Ship no script | Breaks the chain at v5.8.0 for every later upgrade |
| Write the second marker from this script | Writes into adopter git dirs. `/start-ticket` already does that write. |
| Report-only script (chosen) | Keeps the chain walkable and tells the adopter what changed, with no write |

## Decision

Ship `.claude/migrations/v5.8.0-to-v5.9.0.sh`. It prints the two adopter notes and exits 0. It writes no file.

## Rollback Plan

1. Keep `.claude/migrations/v5.8.0-to-v5.9.0.sh`. Never delete a shipped migration script: a fork still on v5.8.0 needs it as the first link of every later upgrade chain.
2. To roll back, replace the script body with a plain no-op that prints one line and exits 0, in a follow-up PR.
3. No adopter data changes, so no adopter step is needed.

**Rollback tested against**: not needed. The script writes nothing.
**Rollback window**: unlimited.

## Cross-Service Consumers

`_lib-migration-chain.sh` finds the script by name and `/update` runs it. No other consumer.

## Testing Plan

- `bash -n` and `shellcheck` pass on the script.
- Run the script with and without `APEXYARD_MIGRATION_QUIET=1`. It exits 0 in both cases. It prints the two notes only when quiet mode is off.

## Observability

The script prints a fixed status line and the two adopter notes during `/update`. `APEXYARD_MIGRATION_QUIET=1` silences it.

## Consequences

- The `/update` chain stays walkable across v5.8.0 for every later upgrade.
- Adopters learn about the second ticket marker and the fail-closed gate, without an automatic edit.
- Each release keeps the cost of one small script, even when nothing moves.

## Architecture evolution

### Before

The migration chain ended at `v5.7.0-to-v5.8.0.sh`.
`/start-ticket` wrote one marker.
The Bash dispatcher warned when `require-active-ticket.sh` crashed.

### After

`v5.8.0-to-v5.9.0.sh` is the next link. It writes no file.
`/start-ticket` writes a second marker into the git dir of the tree that runs it.
Each linked worktree needs its own `/start-ticket`.
The dispatcher and the ticket gate fail closed.
`onFailure` needs Claude Code 2.1.295 or later.

## Artifacts

- Ticket: #1728
- Commits / PRs: release branch `release/v5.9.0`
- Staging-run log: not applicable. The script was run locally in normal mode and in quiet mode.
- Post-apply dashboard snapshot: not applicable

# AgDR-0223: v5.7.0 to v5.8.0 migration is a report-only no-op

> In the context of the v5.8.0 release (#1581), facing the need for a walkable `/update` migration chain, I decided to ship a report-only `v5.7.0-to-v5.8.0.sh` that writes no file, to achieve an unbroken chain for adopters, accepting one small script per release.

**Migration type**: data (framework config, report only)
**Affected tables / entities**: none. The script reads `.claude/project-config*.json` and writes nothing.
**Estimated downtime**: none. The script only prints messages.
**Data volume**: one to three small JSON files per fork
**Target environment(s)**: adopter forks, during `/update`

## Context

`/update` walks `.claude/migrations/` from the fork's version to the target version. The walk stops at a missing link, so a release without a script breaks the chain for every adopter who later upgrades across it (`_lib-migration-chain.sh`).

v5.8.0 moves no adopter file. Two changes still matter to adopters:

- #1537 removes the optional search MCP integration. Any `mcp_search` keys in a fork's config are now unused.
- #1531 gates edits under `.claude/worktrees/` like any other source edit.

## Options Considered

| Option | Result |
|--------|--------|
| Ship no script | Breaks the chain at v5.7.0 for every later upgrade |
| Remove `mcp_search` keys automatically | Writes to adopter config. This is not necessary, because nothing reads the keys. |
| Report-only script (chosen) | Keeps the chain walkable and tells the adopter what changed, with no write |

## Decision

Ship `.claude/migrations/v5.7.0-to-v5.8.0.sh`. It prints the files that still set `mcp_search`, notes the worktree gate, and exits 0. It writes no file.

## Rollback Plan

1. Keep `.claude/migrations/v5.7.0-to-v5.8.0.sh`. Never delete a shipped migration script: a fork still on v5.7.0 needs it as the first link of every later upgrade chain.
2. To roll back, replace the script body with a plain no-op that prints one line and exits 0, in a follow-up PR.
3. No adopter data changes, so no adopter step is needed.

**Rollback tested against**: not needed. The script writes nothing.
**Rollback window**: unlimited.

## Cross-Service Consumers

`_lib-migration-chain.sh` finds the script by name and `/update` runs it. No other consumer.

## Testing Plan

- `bash -n` and `shellcheck` pass on the script.
- Run the script in a fork with and without an `mcp_search` key. It exits 0 in both cases. It prints the file only when the key exists.

## Observability

The script prints a fixed status line, one line for each file that still sets `mcp_search`, and a note about the worktree gate during `/update`. `APEXYARD_MIGRATION_QUIET=1` silences it.

## Consequences

- The `/update` chain stays walkable across v5.7.0 for every later upgrade.
- Adopters learn which config keys are now unused, without an automatic edit to their config.
- Each release keeps the cost of one small script, even when nothing moves.

## Artifacts

- Ticket: #1581
- Commits / PRs: #1582
- Staging-run log: not applicable. The script was run locally with and without an `mcp_search` key, and in quiet mode.
- Post-apply dashboard snapshot: not applicable

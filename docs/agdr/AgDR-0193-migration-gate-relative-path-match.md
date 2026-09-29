---
id: AgDR-0193
timestamp: 2026-09-29T16:30:00Z
agent: platform-engineer
model: composer
session: cursor-1483
trigger: user-prompt
status: executed
category: patterns
---

# Migration match form prefixes relative paths with ./

> In the context of the migration gate missing bare relative `migrations/` writes, facing a spelling gap between `migrations/x` and `./migrations/x`, I decided to prefix relative targets with `./` for pattern matching only, accepting that match form stays separate from resolution normalisation.

## Context

Default migration patterns in `require-migration-ticket.sh` are `*/`-anchored. Example: `*/migrations/*`.

A Write or Bash target spelled `./migrations/001.sql` matches. The same write spelled `migrations/001.sql` does not. The gate then exits 0 with no migration ticket. That is a fail-open on the ordinary relative spelling.

Issue #1483 requires both spellings to block. It also names `sub/../migrations/x`. That spelling already matched on the raw text. The suite still pins it so the fix cannot loosen it.

Selection still asks the raw spelling for which target is governed. Resolution still uses `_rmt_normalise_target`. This change affects only the match form inside `is_migration_path`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Prefix relative paths with `./` before default pattern match | Small. Tightens only. Keeps every spelling that already blocks | Does not collapse `.` / `..` in the match form |
| Lexically collapse then match | Would make `sub/../migrations/x` and `migrations/x` identical | Collapse turns `migrations/../1.sql` into `1.sql` and would allow a write that blocks today |
| Add bare `migrations/*` arms beside `*/migrations/*` | Explicit | Duplicates every default arm. Easy to drift |

## Decision

Chosen: **prefix a bare relative path with `./` for matching only**.

`_rmt_path_for_migration_match` leaves absolute and `~/` and already-`./` paths unchanged. Every other relative path becomes `./<path>`. Default patterns then see the same form for `migrations/x` and `./migrations/x`.

Do not collapse `.` or `..` in the match form. Collapse would drop the `migrations` segment from paths such as `<abs>/migrations/../1.sql` and from relative `migrations/../1.sql` after a `./` prefix. That would loosen the gate. Issue #1483 forbids that.

Custom `migration_paths` still match the original path. They also match the path with a leading `./` stripped. That keeps adopter patterns such as `src/db/**` working.

## Consequences

- Bare relative `migrations/...` writes block without a migration ticket.
- Existing `./migrations/...` and `sub/../migrations/...` blocks stay blocked.
- Absolute path behaviour is unchanged.
- Match form and resolution normalise remain separate helpers.

## Artifacts

- `.claude/hooks/require-migration-ticket.sh` — `_rmt_path_for_migration_match` + `is_migration_path` match form
- `.claude/hooks/tests/test_require_migration_ticket.sh` — #1483 Bash and Write cases
- me2resh/apexyard#1483

## Evolution

The migration gate kept `*/`-anchored default patterns. Match form now prefixes a bare relative path with `./` so `migrations/x` and `./migrations/x` share one match. Selection still uses the raw target string. Resolution still uses `_rmt_normalise_target`. Lexical collapse stays out of the match path so existing blocks such as `migrations/../1.sql` stay blocked.

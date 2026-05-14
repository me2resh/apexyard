ENFORCEMENT: blocking

# Handbook: Migration Safety

**Scope:** all PRs (handbook lives under `architecture/` — Rex always loads it).
**Enforcement:** **blocking** — Rex requests changes if it detects a violation. PR cannot merge until resolved (or the handbook is amended via a separate PR).

## The rule

Database schema migrations must be **backwards-compatible for at least one release**. Any single migration that breaks the previous release's running code is a violation, even if the new code shipping in the same PR no longer needs the old shape.

Concretely, a single migration **MUST NOT** do any of:

| Action | Why it's blocked |
|---|---|
| `DROP COLUMN` or `DROP TABLE` on a column/table the previous release reads or writes | The previous release's deployed instances will crash mid-rollout. Use a two-step migration (deprecate-then-drop across releases) instead. |
| `RENAME COLUMN` or `RENAME TABLE` in a single step | Same reason. Add the new name as a copy, dual-write for one release, drop the old name in a follow-up migration. |
| `ALTER COLUMN` to a more restrictive type or NOT NULL without a default | Existing rows can violate the new constraint mid-migration; in-flight writes from the old code can fail validation. |
| Drop or narrow an enum value the old code might emit | Old instances in a rolling deploy will fail to write. |
| Reorder or change semantics of an existing column without a feature flag | Reads from old code interpret the new data wrong. |

## Why

Production rollouts are not atomic. During a deployment window — anywhere from 30 seconds (single instance) to 30 minutes (canary, regional, mobile-app-update lag) — both the old and new code are running against the same database. A migration that breaks the old code's expectations causes errors, lost writes, or data corruption during the window.

The "backwards-compatible for one release" rule converts every breaking change into a planned two-step over two releases:

```
Release N:   add new column / table / value (additive). Old + new code both work.
Release N+1: switch reads/writes to the new shape. Old code still works because the new shape is additive.
Release N+2: drop the old column / table / value (destructive). Safe because no production code reads it any more.
```

This pattern is slow on purpose. The slowness is the safety.

## What Rex flags

When reviewing a PR, surface a **blocking** finding when:

1. The diff includes a migration file (matches `**/migrate-*.{ts,js,py,sql}`, `**/migrations/**`, `prisma/schema.prisma`, `prisma/migrations/**`, `src/migrations/*.{ts,js}`, `alembic/versions/*.py`, `db/migrate/*.rb`) AND the migration content includes any of:
   - SQL keywords: `DROP COLUMN`, `DROP TABLE`, `RENAME COLUMN`, `RENAME TABLE`, `ALTER COLUMN ... NOT NULL`, `ALTER COLUMN ... TYPE`, `ALTER TYPE ... DROP VALUE`, `DROP TYPE`
   - Prisma schema changes: removed fields on existing models, removed models, narrowed types (String → Int, optional → required), removed enum values
   - TypeORM / Drizzle migration calls: `dropColumn(`, `dropTable(`, `renameColumn(`, etc.

2. AND there is no associated migration AgDR linked in the PR body (the framework's `require-migration-ticket.sh` hook normally enforces this; surface it here too as a defense-in-depth check).

## Sample finding

> ⛔ **Migration safety — BLOCKING**
>
> `prisma/migrations/20260514_drop_legacy_user_role/migration.sql` drops the `users.role_v1` column. The previous release still reads this column in `src/auth/role-resolver.ts:42`. A rolling deploy will cause the old instances to crash on every login request during the deployment window.
>
> **Required fix:** split into two PRs across two releases:
>
> - This release: stop reading `role_v1` (use `role_v2`); leave the column in place. Add an AgDR documenting the deprecation.
> - Next release: drop the column.

## What's NOT a violation

- **Adding** a column / table / enum value (additive — old code ignores it).
- **Adding** an index, constraint that's NOT a NOT NULL or check on existing data, or extension.
- A `DROP` on a column that was added AND deprecated in a prior release (verify by tracing the previous release's code — the column should have zero readers/writers).
- A migration that's purely a data backfill (UPDATE / INSERT) with no schema change.
- A migration on a table no other service touches and that the previous release didn't read (verify cross-service consumers).

## Override

If the violation is intentional and the team has weighed the risk (e.g. a planned downtime window, a column that's verifiably unused), the PR author **must** link a migration AgDR (per `templates/agdr-migration.md`) that explicitly documents:

1. The breaking change being made
2. Why backwards-compatibility is being skipped
3. The downtime / rollback plan
4. The cross-service consumer list verifying no other code reads the dropped shape

With the AgDR linked, Rex marks this handbook check as N/A and the merge proceeds (the AgDR is the audit trail).

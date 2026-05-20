ENFORCEMENT: blocking

# Handbook: Migration Safety (Alembic variant)

**Scope:** PRs touching `alembic/versions/*.py`, `alembic.ini`, or `app/db/models.py`.
**Enforcement:** **blocking** — production rollout safety.

## The rule

Every schema change ships in **two PRs minimum** — never in one:

1. **PR A (backwards-compatible expansion).** Adds the new column / table / index. Old code keeps working. Migration is reversible (Alembic auto-generates a `downgrade()` — verify it).
2. **PR B (consumer migration + cleanup).** Switches the consuming code to use the new shape. After at least one production rollout, drop the deprecated column / table.

This is the **expand-then-contract** pattern. The single-PR alternative breaks rolling deploys.

| Change | PR A | PR B | Minimum production gap |
|---|---|---|---|
| Add a nullable column | One PR — additive | n/a | n/a |
| Add a non-nullable column with `server_default` | One PR — default provides the migration value | n/a | n/a |
| Drop a column | Stop writing; keep reading | After one rollout: drop | 1 deploy cycle |
| Rename a column | Add new column; backfill; dual-write | After one rollout: drop old | 1 deploy cycle |
| Drop a table | Stop reading; keep writes | After one rollout: drop | 1 deploy cycle |
| Add a NOT NULL constraint | Backfill values | Add the constraint in a second PR | 1 backfill cycle |
| Change a column type | Add new column with new type; dual-write; backfill | Drop old column | 2 PRs minimum |

## Why

Alembic migrations apply at deploy time. During a rolling deploy, old and new code coexist for minutes; a one-PR drop+add against a non-empty production table either fails (NOT NULL on missing data) or destroys data (DROP COLUMN before consumers stopped reading). Recovery requires a restore from backup or a hand-written reverse migration; both are expensive.

The expand-then-contract pattern is forwards-AND-backwards-compatible at every point in time. It's the only safe shape for production.

## What Rex flags (BLOCKING)

When the PR touches `alembic/versions/*.py` OR adds a new migration file, surface a **request-changes** finding when:

1. A column is dropped in the same PR that adds its replacement.
2. A NOT NULL constraint is added without a `server_default` AND without evidence of a backfill migration in a prior PR.
3. The migration's `downgrade()` function raises NotImplementedError or has a `pass` body — every migration must be reversible (or explicitly documented as "irreversible: <reason>" in the docstring).
4. A column is renamed in a single statement (`op.alter_column(...)` with a new name) without a dual-write transition.
5. A `op.drop_table(...)` is in the same migration as `op.create_table(...)` for related schemas (suggests rename-via-replace without the gap).
6. The migration uses raw SQL via `op.execute(...)` without a comment explaining why Alembic's typed operations didn't suffice.

## Sample finding

> **Migration safety (BLOCKING)** — `alembic/versions/abc123_drop_user_email.py:14` drops the `users.email` column in the same migration that adds `users.email_address`. This is a contract-only migration; rolling deploys will fail for any container still on the old image. Split into two migrations: (1) add `users.email_address`, dual-write from the application; (2) after one stable rollout, drop `users.email`.

## What's NOT a violation

- Migration on a dev-only table — opt out via a `# dev-only: <reason>` comment in the migration docstring.
- A `op.execute("CREATE INDEX CONCURRENTLY...")` — concurrent index creation is safe in Postgres; flag only blocking index builds.
- A new table — additive, no contract to break.
- A migration that ONLY runs `op.execute("...")` for a one-off data fix — explicitly mark as `# data-fix: not a schema change`.

## Why this handbook is blocking

The cost of a botched Alembic migration — production outage, partial-rollback drama, data loss — is materially higher than the cost of a churn'd PR review. Production-rollout safety is exactly the failure mode that advisory enforcement doesn't catch in time.

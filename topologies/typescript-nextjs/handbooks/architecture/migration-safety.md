ENFORCEMENT: blocking

# Handbook: Migration Safety (Prisma variant)

**Scope:** all PRs touching `prisma/schema.prisma` or files under `prisma/migrations/` (handbook lives under `architecture/` — Rex always loads it, but findings only fire when the diff touches a migration path).
**Enforcement:** **blocking** — production rollout safety.

## The rule

Every schema change ships in **two PRs minimum** — never in one:

1. **PR A (backwards-compatible expansion).** Adds the new column / table / index. Old code keeps working. The migration is reversible.
2. **PR B (consumer migration + cleanup).** Switches the consuming code to use the new shape. After at least one production rollout, drop the deprecated column / table.

This is the **expand-then-contract** pattern. The single-PR alternative — "drop column X, add column Y, update all consumers" — cannot be rolled back without data loss, and breaks rolling deploys (old containers querying the dropped column).

| Change | PR A (expand) | PR B (contract) | Minimum production gap |
|---|---|---|---|
| Add a nullable column | One PR — additive, no contract | n/a | n/a |
| Add a non-nullable column with default | One PR — default provides the migration value | n/a | n/a |
| Drop a column | Stop writing to it; keep reading | After one rollout: drop the column | 1 deploy cycle |
| Rename a column | Add the new column; backfill; dual-write | After one rollout: drop the old column | 1 deploy cycle |
| Drop a table | Stop reading from it; keep writes | After one rollout: drop the table | 1 deploy cycle |
| Add a NOT NULL constraint to existing column | Backfill the column with values; add the constraint in a second PR | n/a (second PR is the constraint) | 1 backfill cycle |

## Why

Production rollouts are not atomic. During a rolling deploy, old and new code coexist for minutes-to-hours. A migration that drops a column while old code is still reading from it causes immediate production errors. A migration that adds a NOT NULL constraint while old code is writing rows without it fails the deploy halfway through.

Worse: **migrations are hard to roll back**. PostgreSQL doesn't have transactional DDL on every statement; a half-applied migration leaves the schema in an inconsistent state. The expand-then-contract pattern is the only way to make every migration **forwards-AND-backwards-compatible at every point in time**.

## What Rex flags

When reviewing a PR that touches `prisma/schema.prisma` OR adds files under `prisma/migrations/`, surface a **blocking** finding when:

1. A column is dropped in the same PR that adds its replacement. (Expand and contract MUST be separate PRs.)
2. A NOT NULL constraint is added without a `DEFAULT` clause AND without evidence of a backfill migration in a prior PR.
3. A column is renamed in a single statement (`ALTER COLUMN ... RENAME TO ...`) without a dual-write window.
4. A table is dropped in the same PR that adds its replacement.
5. The migration file lacks a `-- ROLLBACK:` comment naming the rollback SQL (Prisma doesn't auto-generate rollbacks).

## Sample finding

> **Migration safety (BLOCKING)** — `prisma/migrations/20260520123456_drop_user_email/migration.sql:3` drops the `users.email` column in the same PR that adds `users.email_address`. This is a contract-only migration; the rollout will fail for any container still on the old image during the deploy window. Split into two PRs: (1) add `users.email_address`, dual-write from application code, deploy; (2) after one stable rollout, drop `users.email`.

## What's NOT a violation

- Migration on an empty / dev table (no production data) — opt out by adding `-- dev-only: <reason>` at the top of the migration file. Rex skips the finding.
- Adding an index — index creation is concurrent-safe in Postgres if the migration uses `CREATE INDEX CONCURRENTLY`. Rex flags only if it's a blocking index build.
- Adding a new table — no contract change; no existing consumers to break.
- Removing a column that has been gated behind a feature flag with 0% rollout for ≥ 30 days — note this in the PR description; the reviewer can override the blocking finding.

## Why this handbook is blocking

The cost of a failed production migration — data loss, prolonged outage, partial rollback — is materially higher than the cost of churn'd PR feedback. Production-rollout safety is exactly the failure mode that the framework's general advisory pattern doesn't catch in time. See `handbooks/README.md` § "Enforcement: advisory vs blocking" for the framework's overall policy.

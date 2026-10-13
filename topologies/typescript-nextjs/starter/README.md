# Starter

This tree is a small Next.js application.
TypeScript strict mode is on.
The local store is a SQLite file.

## Commands

Check the build environment:

```bash
npm run check:env
```

Migrate, seed, and start the application:

```bash
npm run dev:fresh
```

Reset local data to the seed:

```bash
npm run data:reset
```

## Session cookie

The session cookie is HttpOnly.
The session cookie uses SameSite=Lax.
Set COOKIE_SECURE to true to add Secure.
That value is the only Secure rule.

## Routes

State-changing routes accept application/json only.
Any other media type returns status 415.
Errors use the application/problem+json media type.
Each error includes a stable code.

## Local store

Drizzle ORM uses the sql.js driver.
The database file is data/app.db.
The seed row name is seed-item.
npm ci --ignore-scripts can install this driver.

## Harnessability

The score is high.

- Type safety is strong. tsconfig.json sets strict to true.
- Module boundaries are strong. The tree has src/domain, src/application, and src/infrastructure.
- Framework opinionation is strong. package.json depends on next.
- The test coverage signal is present. vitest.config.mts sets a line threshold.
- The lint baseline is present. eslint.config.mjs is the ESLint config.

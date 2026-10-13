# Scaffold starter local store

Status: proposed.

## Context

The typescript-nextjs starter needs one local store.
The install must work when npm skips install scripts.
One command migrates, seeds, and starts the application.
One command resets local data to the seed.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Prisma with SQLite | Typed schema | The install script downloads engines |
| Drizzle with better-sqlite3 | Small ORM | The driver compiles native code |
| Drizzle with sql.js | No install script | The driver runs from WebAssembly |

## Decision

Chosen: Drizzle ORM 0.45.4 with sql.js 1.14.2.
The database file is data/app.db.
The seed row name is seed-item.
npm ci --ignore-scripts can install this driver.

A failed environment check keeps sql.js.
The check covers Node, write access, install scripts, and network.
The check prints check=fail, the failed list, and fallback=sql.js.
The check does not switch the ORM.
Fix the failed check.
Then run npm ci --ignore-scripts.

CI uses Node 22.12 or newer.
On Node 22.22, npm ci --ignore-scripts ran the tests.
On Node 20.18, the same command missed the test runner binding.

TypeScript is pinned at 6.0.3.
The linter does not support TypeScript 7.
ESLint is pinned at 9.39.5.
The Next lint plugins do not accept ESLint 10.

## Consequences

- dev:fresh migrates, seeds, and starts the application.
- data:reset deletes the local file and writes the seed.
- Production npm audit --omit=dev reported no findings.
- A full npm audit reported five high findings in development tools.
- The audit gate ignores those development findings.

## Architecture evolution

Before this choice, the bundle named Prisma and shipped no application tree.
After this choice, the starter keeps rows in one SQLite file.
Drizzle ORM reaches that file through sql.js.
A failed environment check still uses sql.js.
The items GET handler returns problem+json when the list fails.
The response uses a stable code and omits the thrown error.
Coverage include lists the source globs, so an untested file counts.
The lock file engines field matches package.json at >=22.12.0.
The generated test command passes `--coverage.reporter=json-summary` once.
The starter test script already passes `--coverage`.
A second `--coverage` flag makes Vitest reject the command.
The starter ignore file lists `.env*`.
It allows `.env.example`.
The copy step skips every other `.env*` file.
The copy step prunes `node_modules`, `.next`, `coverage`, and `data` only at the starter root.
A nested directory with one of those names remains in the copy.
The copy skips `*.tsbuildinfo`.
The topology stack line names Drizzle ORM with sql.js.
A fault job passes only when `npm ci` exits 0 and the gate exits non-zero.
A registry outage makes `npm ci` exit non-zero.
That non-zero install fails the fault job.
The generated gate job runs each floor script in a project that generate.sh builds from good.json.

## Artifacts

- `topologies/typescript-nextjs/starter/`
- `topologies/typescript-nextjs/VERSION`
- `topologies/typescript-nextjs/starter/scripts/check-env.sh`

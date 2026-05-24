# Handbook: Clean Architecture Layering

**Scope:** all PRs (handbook lives under `architecture/` — Rex always loads it).
**Enforcement:** advisory.

## The rule

Code in this codebase is organised in three layers with a strict dependency direction:

```
domain  ←  application  ←  infrastructure
```

Dependencies point **inward**. The outer layers know about the inner; the inner layers do not know about the outer.

| Layer | What lives there | What it CAN import | What it CANNOT import |
|---|---|---|---|
| `domain/` | Entities, value objects, domain events, business invariants | Other domain modules, standard library, primitive types | Anything from `application/`, `infrastructure/`, frameworks (HTTP, DB, message queues), env-var reads, network calls |
| `application/` | Use cases, command/query handlers, orchestration of domain operations | `domain/`, ports/interfaces it owns | `infrastructure/` (concrete adapters, drivers, SDKs) |
| `infrastructure/` | DB clients, HTTP handlers, queue producers/consumers, third-party SDK wrappers, config readers | `application/` (to call use cases), `domain/` (to construct entities), external libraries | (no restriction — this is the outermost layer) |

## Why

The dependency rule is what makes the domain testable without infrastructure mocks, swappable across deployments (DynamoDB → Postgres without changing business rules), and stable as the framework / hosting / vendor choices change underneath.

When this gets violated — e.g. a domain entity importing the AWS SDK to fetch its own data — the domain becomes welded to the infrastructure. Test setup balloons. Refactoring the database becomes "rewrite the business logic". Three months in, the team stops touching the domain.

## What Rex flags

When reviewing a PR, surface a finding when:

1. A file under `**/domain/**` imports from `**/infrastructure/**`, `**/application/**`, or any third-party framework module (e.g. `@aws-sdk/*`, `express`, `next`, `axios`, `prisma`).
2. A file under `**/application/**` imports from `**/infrastructure/**` (the application layer should depend on ports/interfaces it owns, not on concrete adapters).
3. A use case under `**/application/**` reads `process.env` directly (config should arrive as constructor arguments from infrastructure).
4. A domain entity has a method that performs I/O — looks for `await fetch`, `await db.`, `await client.`, or imports of HTTP/DB clients inside the entity body.

## Sample finding

> **Layering** — `src/domain/order.ts` imports `@aws-sdk/client-dynamodb`. The domain layer must not depend on infrastructure SDKs. Move the persistence concern to `src/infrastructure/order-repository.ts` and let the use case in `src/application/place-order.ts` orchestrate the two.

## What's NOT a violation

- Type-only imports across layers (e.g. `import type { Order } from '../domain/order'` in `infrastructure/`) are fine — they're erased at compile time and don't create runtime coupling.
- A domain module importing a small pure-function library (e.g. `date-fns`, `zod` for validation) is fine — these aren't infrastructure, they're extended primitives.
- An adapter under `infrastructure/` importing `application/` to fulfil a port is the *correct* direction.

## Refactor recipe

If you spot a violation in code that's already shipped:

1. Identify the offending import in `domain/`.
2. Sketch the missing port — what *interface* does the domain need? Define it as an abstract class or TS interface inside `domain/` (no implementation).
3. Move the concrete implementation to `infrastructure/` — make it implement the port.
4. Wire it up in `application/` via constructor injection.
5. Tests for the domain now mock the port, not the SDK.

The refactor is mechanical once you see the shape. The hard part is noticing the violation in the first place — which is what this handbook is for.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

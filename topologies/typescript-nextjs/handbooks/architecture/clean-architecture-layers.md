# Handbook: Clean Architecture Layering (Next.js variant)

**Scope:** all PRs in a Next.js project (handbook lives under `architecture/` — Rex always loads it).
**Enforcement:** advisory.

## The rule

A Next.js codebase that ApexYard's topology bundle expects is organised in three layers with a strict dependency direction, mapped onto Next.js's own directory conventions:

```
domain/  ←  app/  ←  lib/infrastructure/
```

| Layer | Maps to | What lives there | CAN import | CANNOT import |
|---|---|---|---|---|
| `domain/` | `domain/` at repo root (NOT inside `app/`) | Entities, value objects, domain events, pure business invariants | Other domain modules, standard library | Anything from `app/`, `lib/`, Next.js APIs (`next/*`), React |
| `app/` (route handlers + server components) | `app/api/**/route.ts`, `app/**/page.tsx` (server components only — `"use server"` or default) | Orchestrates use-cases, handles HTTP boundary, renders UI server-side | `domain/`, `lib/application/` (use-case layer if present), `lib/infrastructure/` ports it OWNS | Concrete vendor SDKs (`@aws-sdk/*`, `@prisma/client` directly) — go through `lib/infrastructure/` |
| `lib/infrastructure/` | `lib/db/`, `lib/email/`, `lib/queue/`, `lib/auth/` | Prisma client, Resend/SendGrid wrappers, BullMQ producers, NextAuth adapters | `domain/` (to construct entities), external libraries, env-var reads | (no restriction — outermost layer) |

## Why

Next.js encourages co-locating data fetches in components and route handlers. That convention is fine for a prototype; it doesn't scale to a codebase with non-trivial business rules. Domain logic embedded in a Server Component cannot be tested without spinning up the Next.js render pipeline, cannot be reused in a background worker, and gets entangled with framework lifecycle (revalidation, caching tags) it has no business knowing about.

This layering keeps the domain pure, makes use-cases testable without Next.js mocks, and lets the team swap auth providers (NextAuth → Clerk → Auth.js) without touching business logic.

## What Rex flags

Surface a finding when:

1. A file under `domain/` imports from `next/*`, `react`, `app/*`, or `lib/*` (other than another `domain/` file).
2. A file under `app/` directly imports `@prisma/client`, `@aws-sdk/*`, or other vendor SDKs without going through a `lib/infrastructure/<vendor>/` wrapper.
3. A Server Component (`app/**/page.tsx` without `"use client"`) constructs database queries inline rather than calling a use-case from `lib/application/`.
4. A file under `lib/infrastructure/` re-exports its concrete vendor types as the public API — should expose a port (TypeScript interface defined in `domain/` or `lib/application/`) instead.

## Sample finding

> **Clean architecture (Next.js)** — `app/dashboard/page.tsx:12` calls `prisma.user.findMany()` directly inside the Server Component. Move the query into a use-case in `lib/application/dashboard/getDashboardData.ts` that takes a `UserRepository` port; have `lib/infrastructure/db/PrismaUserRepository.ts` provide the implementation. The Server Component then calls the use-case and stays free of vendor types.

## What's NOT a violation

- `app/api/auth/[...nextauth]/route.ts` re-exporting `NextAuth(...)` config — that file IS infrastructure, even though it lives under `app/`. Mark the file with a `// nextjs-boundary: infrastructure` comment to suppress the finding.
- `lib/infrastructure/` files importing each other (e.g. the email adapter using the queue adapter to send async emails). Outermost layer; no inbound dependency rule applies.
- Prototype code under `app/(prototype)/` — Next.js route groups; mark with a top-of-file comment `// prototype: dependency rules suspended` to opt-out per file.

## Why this is its own handbook (not the universal one)

The universal `clean-architecture-layers.md` (in `handbooks/architecture/`) names `src/domain/`, `src/application/`, `src/infrastructure/`. Next.js doesn't use a `src/` root by default — the directory shape is `app/`, `lib/`, and the project's own `domain/` if the team adds it. This topology-specific variant maps the universal rule onto the Next.js shape so adopters don't see false positives from the universal one.

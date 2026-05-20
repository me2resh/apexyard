# Topology: TypeScript Next.js Web App

**Version**: 1.0.0
**Stack**: TypeScript + Next.js (App Router) + Prisma ORM + Vercel/Node.js runtime
**Use this when**: building a SaaS web app with API routes, server components, a relational DB, and a per-tenant auth model.

## What this topology bundles

Pick this topology in `/handover` and the skill instantiates the following into the new project:

| Layer | Files instantiated | Where they land |
|-------|--------------------|-----------------|
| Architecture handbooks | `clean-architecture-layers.md`, `migration-safety.md` (always-load) | `handbooks/architecture/` |
| Language handbooks | `strict-mode.md`, `error-boundaries.md`, `server-vs-client-components.md` | `handbooks/language/typescript/` |
| Domain handbooks | `nextjs-routing/page-vs-route-handler.md`, `nextjs-auth/session-handling.md`, `nextjs-data/loading-patterns.md` | `handbooks/domain/<area>/` (each has `paths:` frontmatter) |
| CI pipeline | `nextjs-ci.yml` (typecheck + lint + test + build + bundle-size guard) | `.github/workflows/` |
| AgDR template | `agdr-typescript-nextjs.md` (state-management library, ORM choice, auth provider prompts) | `docs/agdr/agdr-typescript-nextjs.draft.md` |

## Why pick this topology

Next.js is one of the most opinionated web frameworks in the TypeScript ecosystem — it dictates routing, data loading, server-vs-client boundaries, and image optimisation. Combined with TS strict mode and a typed ORM (Prisma), the **ambient affordances** are high: the framework already enforces most of the structural rules a code reviewer would otherwise have to surface. ApexYard's harness leans into that — variety reduction per Ashby's Law (see AgDR-0048).

If your codebase uses TypeScript but **not** Next.js (e.g. Express + React SPA, Vite + standalone API), this topology will over-fit. Run `/handover` without picking a topology and lean on the framework's universal handbooks.

## Ambient affordances this topology assumes

| Affordance | How it's provided | Why it matters to Rex |
|------------|-------------------|------------------------|
| Strict TypeScript | `tsconfig.json` with `"strict": true` + `"noUncheckedIndexedAccess": true` | Rex's `language/typescript/strict-mode.md` handbook fires cleanly; blocking enforcement is safe |
| Module boundaries | `app/` (UI) + `lib/` (utilities) + `prisma/` (data) + `domain/` (business logic, optional) | Clean-architecture handbook can flag layer violations |
| Framework opinionation | Next.js App Router conventions; file-system routing; React Server Components | Domain handbooks on routing patterns are enforceable |
| Test coverage signal | `vitest.config.ts` with `coverage.thresholds` block (recommended) | Coverage gates apply |
| Lint baseline | `eslint.config.js` extending `next/core-web-vitals` | ESLint integration is the baseline |

If your project is missing one or more of these, the harnessability assessment (`/handover` step 4.5, AgDR-0042) will surface the gap before any code review noise materialises.

## Files in this bundle

```
typescript-nextjs/
├── VERSION
├── README.md                                                 ← this file
├── handbooks/
│   ├── architecture/
│   │   ├── clean-architecture-layers.md                      ← always-load
│   │   └── migration-safety.md                               ← always-load, blocking
│   ├── language/
│   │   └── typescript/
│   │       ├── strict-mode.md                                ← diff-match on *.{ts,tsx}
│   │       ├── error-boundaries.md                           ← diff-match on *.{ts,tsx}
│   │       └── server-vs-client-components.md                ← diff-match on *.{ts,tsx}
│   └── domain/
│       ├── nextjs-routing/
│       │   └── page-vs-route-handler.md                      ← paths: app/**/page.tsx, app/**/route.ts
│       ├── nextjs-auth/
│       │   └── session-handling.md                           ← paths: app/api/auth/**, middleware.ts
│       └── nextjs-data/
│           └── loading-patterns.md                           ← paths: app/**/page.tsx, lib/data/**
├── golden-paths/
│   └── nextjs-ci.yml                                         ← typecheck + lint + test + build + bundle-size
└── templates/
    └── agdr-typescript-nextjs.md                             ← state-management / ORM / auth-provider prompts
```

## How re-instantiation works

When `/update` detects this topology's framework `VERSION` is ahead of the instantiated copy at `handbooks/architecture/clean-architecture-layers.md` etc., it offers per-file diff acceptance. Default is **skip** — the operator owns each change, same convention as the deprecated-config-key offer in `/update` step 8 (see AgDR-0032).

To force a clean re-instantiation: delete the instantiated files and re-run `/handover --topology typescript-nextjs`. The skill never overwrites without confirmation.

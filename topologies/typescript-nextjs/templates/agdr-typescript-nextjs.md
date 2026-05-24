# {Short Title — e.g. "Choosing a state-management library for the dashboard"}

> In the context of {context — Next.js App Router project, what feature drove the decision}, facing {concern — e.g. "shared state across server-rendered pages and client-side filters"}, I decided {decision — e.g. "use Zustand only at the leaf, with URL state for filters"} to achieve {goal — e.g. "RSC stays the data source, client state stays small"}, accepting {tradeoff — e.g. "another dep, learning curve for the team"}.

## Context

{Decision-relevant context only. What part of the Next.js stack triggered this? Server Components, Server Actions, the data layer, the auth setup, deployment target (Vercel / self-hosted / Docker)?}

## Options Considered

> ApexYard's TypeScript-NextJS topology v1.0.0 ships this template with stack-specific option prompts. Fill in the rows that apply; delete the rest. Don't feel obliged to consider every option — pick the 2-3 that were genuinely on the table.

### A) State management

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **URL state (searchParams)** | Server-renderable, shareable, browser-back works | Limited to serialisable; verbose for nested state | |
| **React Context + useReducer** | Built-in, zero deps | Re-render cascades; awkward for deeply-nested updates | |
| **Zustand** | Tiny (~1 kB), no provider wrap, easy migration off later | Another dep; client-only by definition | |
| **Jotai** | Atomic, fine-grained reactivity, RSC story improving | Steeper learning curve | |
| **Redux Toolkit** | Battle-tested, devtools, broad ecosystem | Heavyweight for small apps | |

### B) ORM / data access

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Prisma** | Schema-first, great TS DX, broad DB support, migrations included | Generated client is heavy on serverless cold starts; migration tooling is opinionated | |
| **Drizzle** | Lighter, SQL-like, edge-runtime friendly | Smaller ecosystem; migration tooling less mature | |
| **Kysely** | SQL builder with great types; no codegen | More verbose; need to wire migrations yourself | |
| **Raw SQL + small driver (`postgres`, `mysql2`)** | Total control, smallest footprint | No type safety on queries unless you build it | |

### C) Auth provider

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Auth.js (next-auth v5)** | Tight Next.js integration, OAuth + credentials, self-hostable | Active rewrite; some footguns around session strategy | |
| **Clerk** | Hosted UI, MFA + organisations out of the box | $$ at scale; vendor lock-in for the UI | |
| **Lucia + custom session table** | Full control, lean, type-safe | More code to write and own | |
| **WorkOS / Auth0 / Okta** | Enterprise SSO, audit trails | $$$; usually overkill until you have enterprise customers | |

### D) Hosting

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Vercel** | Best Next.js runtime; ISR, edge fns, Image Optimizer all "just work" | Vendor lock-in; cost at scale; private endpoints harder | |
| **Self-hosted (Docker + Node)** | Full control, runs anywhere | You own the Image Optimizer, ISR cache, edge story | |
| **Cloudflare Pages + Workers** | Edge-first, good Workers integration | Some Next features (ISR) require workarounds | |
| **AWS Amplify** | Tight AWS integration | Less Next-aware than Vercel; provider quirks | |

### E) Testing strategy

| Option | Pros | Cons | Picked? |
|--------|------|------|---------|
| **Vitest + Testing Library + Playwright** | Modern, fast, good TS support; Playwright for E2E | Three tools to learn | |
| **Jest + Testing Library + Cypress** | Battle-tested combo | Slower than Vitest; some quirks with ESM | |
| **Just E2E (Playwright)** | Tests the real boundary; fewer fragile mocks | Slow; CI cost | |

## Decision

Chosen: **{the option}**, because {2-3 sentences naming the load-bearing reason. Reference the topology's ambient affordances if applicable — e.g. "the topology assumes Prisma; sticking with it keeps Rex's migration-safety handbook applicable"}.

## Consequences

- {Specific consequence for the codebase — e.g. "Every server-side data fetch now goes through `lib/db/PrismaClient.ts`"}
- {Consequence for dev workflow — e.g. "Migration commits get the `migration` label and AgDR per workflow-gates.md"}
- {Consequence for deploy — e.g. "Vercel Edge Functions are out for this app; all runtime is Node"}
- {Consequence for testing — e.g. "Integration tests use a docker-compose Postgres; CI runs them in the same workflow"}

## Artifacts

- {Commit / PR links}
- {Updated configs — `tsconfig.json`, `next.config.js`, `prisma/schema.prisma`}
- {Affected handbooks — link to the topology handbooks this decision relies on}

## What this decision does NOT cover

- {Be explicit about scope. "State for the marketing site is out of scope; this decision applies to the authenticated dashboard only."}
- {Cross-reference future AgDRs if applicable — "Caching strategy is a separate AgDR (TBD)."}

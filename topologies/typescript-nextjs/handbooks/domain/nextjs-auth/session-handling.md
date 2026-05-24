---
paths:
  - "app/api/auth/**"
  - "middleware.ts"
  - "app/**/(authenticated)/**"
  - "lib/auth/**"
---

ENFORCEMENT: blocking

# Handbook: Session handling — auth boundaries in Next.js

**Scope:** PRs that touch the auth subsystem — `app/api/auth/**`, `middleware.ts`, `lib/auth/**`, or any segment under an `(authenticated)` route group.
**Enforcement:** **blocking** — security-critical surface.

## The rule

Every protected route enforces session checks **at the boundary**, not in leaf components. The boundary is one of:

| Boundary | Mechanism | When |
|---|---|---|
| Middleware (`middleware.ts`) | Match auth route pattern; redirect unauthenticated | Coarse-grained ("everything under `/dashboard` requires login") |
| Layout (`app/(authenticated)/layout.tsx`) | Call `auth()` / `getServerSession()`; redirect/throw if missing | Per-segment-group ("the authenticated app vs the marketing site") |
| Server Component | Call `auth()` at the top of the page; check role | Per-page authorisation (admin-only pages, owner-only resources) |
| Route Handler | Call `auth()` first thing; return 401 if missing | API routes — every handler enforces its own auth |
| Server Action | Call `auth()` first thing in the action body | Per-mutation authorisation |

**Never** check session inside a leaf client component and trust the result. Client checks are advisory UX; the server must enforce.

| Anti-pattern | Why it's broken |
|---|---|
| `if (!session) return <LoginPrompt />` in a client component, with the protected resource also rendered server-side | The server already rendered the resource into the HTML before the client check ran. Disclosure. |
| Middleware-only auth on API routes | If middleware misconfigures (path match wrong, header passthrough), the route handler runs anyway. Defence in depth requires the handler to also check. |
| Trusting a client-set cookie name without server-side verification of the session token | Anyone can set a cookie. The server must verify the signature / lookup the session record. |
| Calling `auth()` once in a layout AND assuming children get the result via React context | Server components don't share React context with siblings the way client components do. Each protected page calls `auth()` itself or uses a server-side context (which is a different mechanism). |

## Why

Auth is the highest-blast-radius surface in any web app. A session-handling bug usually shows up as one of: (1) unauthenticated user sees authenticated content; (2) user A sees user B's data; (3) the "logout" action leaves a valid session token. All three are CVE-class. The blocking enforcement isn't paranoia — it's matching the cost of the failure mode.

The reason this is **per-topology** (not in the universal handbooks) is that Next.js's auth boundary is unusually subtle. RSC + Server Actions + middleware + route handlers all have different session-access primitives; getting the boundary right requires knowing which primitive applies where.

## What Rex flags (BLOCKING)

Surface a **request-changes** finding when:

1. A new route under `app/(authenticated)/` is added AND `app/(authenticated)/layout.tsx` doesn't call `auth()` / `getServerSession()` AND no `middleware.ts` matcher covers it. (Auth gap.)
2. A new `app/api/**/route.ts` handler doesn't call `auth()` as the first statement (after the `export async function GET/POST/...`) — even if middleware covers the path.
3. A new Server Action (`"use server"` function) doesn't check `auth()` before any mutation.
4. A `middleware.ts` matcher uses a regex that has known gaps (e.g. `'/dashboard'` without `'/dashboard/(.*)'` — only matches the root, misses children).
5. A client component renders a protected resource (e.g. user PII) before a server-side auth check happened in an ancestor.
6. The auth helper (`lib/auth/session.ts` or equivalent) doesn't validate the session token signature; trusts the cookie value at face value.

## Sample finding

> **Auth (BLOCKING)** — `app/api/orders/[id]/route.ts:3` exports `GET` without calling `auth()` first. Even though `middleware.ts` matches `/api/(.*)`, the matcher excludes `app/api/health/**` via the same regex and the rule is fragile to future changes. Call `auth()` inside the handler as defence-in-depth and return 401 on missing session.
>
> **Auth (BLOCKING)** — `app/(authenticated)/admin/users/page.tsx:5` renders the user list without checking the session's role. `auth()` returned a session, but the layout only enforced "must be logged in", not "must be admin". Add `if (session.user.role !== 'admin') redirect('/unauthorised')` at the top of the page.

## What's NOT a violation

- Public marketing pages (`app/(marketing)/**`) — opt out via the route group name; not protected, no auth check expected.
- Webhook handlers (`app/api/webhooks/stripe/route.ts`) — auth via signature verification, not session. The handler must still verify the signature, but won't call `auth()`.
- Public API routes with their own API-key check (`app/api/v1/**` with bearer-token auth) — the boundary is bearer-token verification; same principle, different primitive.
- Health-check / readiness endpoints (`app/api/health/route.ts`) — explicitly unauth'd; mark with `// public: no auth required` comment.

## The standard pattern

```ts
// app/api/orders/route.ts
import { auth } from "@/lib/auth";
import { NextResponse } from "next/server";

export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user) {
    return NextResponse.json({ error: "Unauthorised" }, { status: 401 });
  }

  // session.user is now typed; use session.user.id for authorisation
  const orders = await listOrdersForUser(session.user.id);
  return NextResponse.json(orders);
}
```

Every route handler follows this shape. Server Actions follow the same shape inside the function body. Layouts call `auth()` and either redirect or proceed.

## Threat model link

See the project's `docs/threat-model.md` for the full STRIDE breakdown of the auth subsystem. This handbook enforces the rules; the threat model captures the why and the residual risks. If your project doesn't have one yet, run `/threat-model` against the auth subsystem after the first handover.

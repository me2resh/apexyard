---
paths:
  - "app/**/page.tsx"
  - "app/**/layout.tsx"
  - "lib/data/**"
  - "lib/db/**"
---

# Handbook: Data loading patterns in App Router

**Scope:** PRs that touch Server Components, Layouts, or the data-access layer.
**Enforcement:** advisory.

## The rule

Data fetching in the App Router has a small set of correct patterns. Pick the one that matches the data's lifetime:

| Data lifetime | Pattern | Cache directive |
|---|---|---|
| Static at build time, never changes | `fetch(url)` (default cached) OR direct DB call from Server Component | No directive needed |
| Stable for N seconds; tolerable staleness | `fetch(url, { next: { revalidate: N } })` | Time-based revalidation |
| Changes on user mutation; revalidate on demand | `fetch(url, { next: { tags: ['orders'] } })` + `revalidateTag('orders')` on mutation | Tag-based revalidation |
| Per-request, never cache | `fetch(url, { cache: 'no-store' })` OR `cookies()` / `headers()` (force-dynamic) | Opt-out of caching |
| User-specific (session-bound) | Direct DB call after `auth()` | Implicitly dynamic |

**Don't:**

- Fetch in a `useEffect` from a Client Component when the data could have been resolved server-side.
- Stack multiple unrelated `await`s in series inside one Server Component when they could run in parallel via `Promise.all`.
- Use `fetch` to call the project's own API routes from a Server Component (e.g. `fetch('/api/orders')`). Call the underlying function directly — no HTTP roundtrip needed.

## Why

Next.js's `fetch` + Server Component combination is the framework's killer feature: data is resolved at request time on the server, streamed into the HTML, and the client never makes a roundtrip. Use it right and the page is fast, SEO-friendly, and has zero hydration cost for the data.

Use it wrong — fetch in a Client Component, or self-call the project's own API — and you've reintroduced every problem RSC was designed to solve: client waterfall, loading spinners, mismatched cache state between server and client.

## What Rex flags

Surface a finding when:

1. A Client Component uses `useEffect` + `fetch` to load data that's already known server-side (no user interaction needed). Move the fetch to the Server Component ancestor.
2. A Server Component calls `fetch('/api/...')` against the project's own API routes. Replace with a direct call to the function the route handler uses.
3. A page makes ≥ 2 independent `await` calls in series. Use `const [a, b] = await Promise.all([fetchA(), fetchB()])` to run them in parallel.
4. A `fetch` call lacks any cache directive AND the response is non-trivial (DB / API call). The default cache might surprise — be explicit with `{ next: { revalidate } }` or `{ cache: 'no-store' }`.
5. A mutation (Server Action, route handler POST) doesn't call `revalidateTag(...)` / `revalidatePath(...)` for the data it just changed. Stale data on next render.

## Sample finding

> **Data loading** — `app/dashboard/page.tsx:8-12` runs `await getOrders()` then `await getUsers()` in series. They're independent — use `const [orders, users] = await Promise.all([getOrders(), getUsers()])` to halve the page's data-loading time.
>
> **Data loading** — `app/dashboard/RecentActivity.tsx:14` uses `useEffect` + `fetch('/api/activity')`. The component is always rendered with the dashboard, no interaction needed. Move the fetch to `app/dashboard/page.tsx` (Server Component), pass the data as a prop, and remove the `useEffect`. The client bundle shrinks by ~3 kB and the user sees the data in the initial HTML.
>
> **Data loading** — `app/orders/page.tsx:5` calls `fetch('/api/orders')`. The route handler at `app/api/orders/route.ts` calls `listOrders()`. The page should call `listOrders()` directly — no HTTP roundtrip, no double JSON parse, simpler error handling.

## What's NOT a violation

- `useEffect` + `fetch` for genuinely user-driven loads (search-as-you-type, polling a live status). That's the right shape; client-side fetching is what `useEffect` is for.
- `fetch` to a third-party API (Stripe, internal microservice) — those need HTTP; nothing to inline.
- Sequential `await`s when one depends on the other (`const user = await getUser(); const orders = await getOrdersFor(user.id)`). That's not parallelisable.
- `cache: 'no-store'` on a request-specific endpoint (per-user dashboard) — exactly the right opt-out.

## Pattern — the standard data-loading page

```tsx
// app/dashboard/page.tsx
import { Suspense } from "react";
import { getOrders, getUsers } from "@/lib/data/dashboard";
import { OrdersList } from "./OrdersList";
import { UsersList } from "./UsersList";

export default async function DashboardPage() {
  // Parallel; don't await sequentially
  const [orders, users] = await Promise.all([
    getOrders(),
    getUsers(),
  ]);

  return (
    <main>
      <h1>Dashboard</h1>
      <Suspense fallback={<p>Loading…</p>}>
        <OrdersList orders={orders} />
      </Suspense>
      <Suspense fallback={<p>Loading…</p>}>
        <UsersList users={users} />
      </Suspense>
    </main>
  );
}
```

`getOrders` and `getUsers` live in `lib/data/dashboard.ts` and call the DB directly (via the infrastructure layer's repository ports — see the architecture handbook). The page is a thin orchestrator.

## Cache invalidation

Every mutation MUST invalidate the data it changed. Common mistake: Server Action creates an order, returns success, the order list page still shows the old data.

```ts
// lib/actions/createOrder.ts
"use server";
import { revalidateTag } from "next/cache";

export async function createOrder(formData: FormData) {
  // ... validation, auth, DB write
  revalidateTag("orders");                 // matches fetch(url, { next: { tags: ['orders'] } })
  // OR: revalidatePath("/orders");        // if you're using path-based revalidation
}
```

Tag-based revalidation is more precise than path-based; prefer tags for non-trivial apps.

# Handbook: Server vs Client Components (Next.js App Router)

**Scope:** PRs touching `**/*.{ts,tsx}` files in a Next.js App Router project.
**Enforcement:** advisory.

## The rule

Components default to **server** in the App Router. Add `"use client"` only when the component genuinely needs client-side capability (state, effects, browser-only APIs). Don't sprinkle `"use client"` reflexively — every `"use client"` boundary ships JS to the browser and breaks RSC streaming.

| Component shape | Default | Why |
|---|---|---|
| Pure presentational (renders props → JSX) | Server | No client capability needed; zero JS to ship |
| Reads data at render time (DB query, API call) | Server | Data fetching is the killer use case for RSC |
| Uses `useState` / `useEffect` / `useReducer` | Client (`"use client"`) | Hooks only run client-side |
| Uses browser APIs (`window`, `localStorage`, `IntersectionObserver`) | Client | Server has no DOM |
| Calls a Server Action via `<form action={...}>` | Server (the form can stay server) | The Action is the boundary; the form itself doesn't need JS |
| Calls a Server Action via `useFormState` or `useTransition` | Client | The hooks are client-side |
| Wraps a third-party library with `"use client"` in its types | Client (transitively) | The library forced the boundary; minimise the surface |

## Why

Every `"use client"` boundary ships the component's JS bundle to the browser, breaks RSC streaming for that subtree, and re-introduces the hydration problem RSC was designed to avoid. Splash a few `"use client"`s without thinking and you've effectively shipped a SPA — the framework's headline benefit (server-rendered React with zero hydration cost for pure-presentation subtrees) is gone.

The reverse mistake — keeping a hook-using component as a server component — produces a build error, so the framework already catches that. The harder mistake is the silent one: components that don't NEED client capability but are marked `"use client"` because the developer didn't know the default.

## What Rex flags

Surface a finding when:

1. A component has `"use client"` AND doesn't use any client-only API (no `useState`, `useEffect`, `useReducer`, `useContext`, no browser globals, no `useFormState`). Common culprit: copy-paste'd a component template that had `"use client"` for an unrelated reason.
2. A component imports `useState` AND wraps a static subtree that doesn't need it. Move the stateful logic into a small client component leaf; keep the wrapper server.
3. A component renders a Server Component **inside** a Client Component (which doesn't work — server components can't be children of client components). The fix: pass server components as children/props from a server component above.
4. Data fetching happens inside a Client Component via `useEffect` + `fetch`. Prefer fetching in the parent Server Component and passing the data as props.
5. A component imports `next/headers` or `next/cookies` AND is marked `"use client"` — these only work in Server Components; the import will fail at runtime.

## Sample finding

> **Server vs Client components** — `app/dashboard/StatsCard.tsx:1` has `"use client"` but uses no client APIs (`useState`/`useEffect`/`useContext` not imported). Remove the directive; the component will server-render, save ~1.2 kB on the client bundle, and become a leaf in the RSC stream.
>
> **Server vs Client components** — `app/dashboard/page.tsx` is marked `"use client"` and fetches data with `useEffect` + `fetch`. Move the fetch to the Server Component (default — remove `"use client"`); the page renders with the data already in the HTML, no client-side waterfall.

## What's NOT a violation

- A component using `"use client"` purely to receive a callback prop from a client parent — that's a real client boundary (callbacks need a serialisable function on the client side).
- A component using `"use client"` because it wraps a third-party client-only library (Mapbox, Stripe Elements, Tiptap) — flag the library's boundary, not the wrapper.
- A leaf component using `"use client"` to handle a button click (`onClick`) — that's a real client need.

## Pattern — composition over over-eager `"use client"`

If you find yourself wanting to mark a large component `"use client"` because one small subtree needs state, **invert the composition**:

```tsx
// app/dashboard/page.tsx (Server Component — default)
import { ChartCard } from "./ChartCard";       // server
import { InteractiveFilter } from "./InteractiveFilter"; // client

export default async function DashboardPage() {
  const data = await getDashboardData();      // server fetch
  return (
    <main>
      <h1>Dashboard</h1>
      <InteractiveFilter>
        <ChartCard data={data} />            {/* server, passed as children */}
      </InteractiveFilter>
    </main>
  );
}
```

`InteractiveFilter` is `"use client"` and uses `useState` for the filter UI. `ChartCard` is server-rendered with the data already resolved. The boundary is exactly the size it needs to be.

## The "use server" directive — not the same thing

`"use server"` is for **Server Actions**, not for forcing a component to be server-rendered (that's the default already). Don't confuse the two — if you see `"use server"` at the top of a component file (not a function), the developer meant `"use client"` or wrote a no-op.

# Handbook: Error Boundaries (Next.js variant)

**Scope:** PRs touching `**/*.{ts,tsx}` files in a Next.js project.
**Enforcement:** advisory.

## The rule

Every route segment that can fail MUST have an `error.tsx` (or `error.ts` for non-component routes) boundary. Server-side errors propagate to the nearest `error.tsx` boundary; without one, the user sees the global 500 page.

| Layer | Required boundary | What it must do |
|---|---|---|
| Layout-level (e.g. `app/dashboard/layout.tsx`) | `app/dashboard/error.tsx` | Catch render errors in any page under this layout; offer "try again" |
| Page-specific (e.g. `app/checkout/page.tsx`) | `app/checkout/error.tsx` (recommended) | Catch errors specific to this page; finer-grained recovery UI |
| Global | `app/global-error.tsx` | Catches errors in `app/layout.tsx` itself; renders its own `<html>` |
| Route handler (`app/api/**/route.ts`) | Try/catch with `NextResponse.json({ error }, { status })` | Return typed error response; never let an exception bubble out |

## Why

Next.js's default 500 page is generic, branded "Application error: a client-side exception has occurred", and gives the user no recovery path. Worse: route segments that throw on the server side cause the WHOLE layout to unmount, losing client state (open dialogs, form drafts) the user didn't expect to lose.

A well-placed `error.tsx` keeps the layout chrome rendered (nav, footer, breadcrumbs) and re-renders only the failed segment. The user gets context + a recovery action. The bug doesn't read like a catastrophic crash.

## What Rex flags

Surface a finding when:

1. A new `page.tsx` is added in a segment that has **no `error.tsx`** in any ancestor under `app/`. (Walk up from the page; if the closest `error.tsx` is `app/error.tsx`, that's OK for prototypes but flag for production routes.)
2. A new `layout.tsx` is added without a sibling `error.tsx` AND the layout is the entry point for a feature area (heuristic: has nested routes under it).
3. A route handler (`app/api/**/route.ts`) has a top-level `await` without a surrounding `try/catch`. Unhandled rejections in route handlers return a generic 500 with no body.
4. A `global-error.tsx` is missing from `app/`. This is the only boundary that catches errors in `app/layout.tsx` itself.
5. An `error.tsx` doesn't accept the `reset: () => void` prop and call it from a retry button — the boundary becomes a dead-end.

## Sample finding

> **Error boundaries** — `app/checkout/page.tsx` added with no `error.tsx` in the segment or any ancestor under `app/`. A render error in the checkout flow will unmount the whole layout (nav + cart drawer + dialog state). Add `app/checkout/error.tsx` with a `"use client"` boundary that calls `reset()` from a retry button.
>
> **Error boundaries** — `app/api/orders/route.ts:14` has `await prisma.order.create(...)` outside a try/catch. If Prisma throws (constraint violation, connection drop), the handler returns a generic 500 with an empty body — the client can't surface a useful error. Wrap in try/catch and return `NextResponse.json({ error: 'Order creation failed' }, { status: 500 })`.

## What's NOT a violation

- Prototype routes under `app/(dev)/` or `app/(prototype)/` — opt out via a top-of-file comment `// prototype: error boundary not required`.
- API routes that return early on validation failure (Zod parse error → 400 response) — the validation IS the error handling; no try/catch needed if the path is exhaustively guarded.
- Static pages with no data fetching (pure JSX) — can't throw at request time; no boundary needed.

## Pattern — the standard `error.tsx`

```tsx
"use client";

import { useEffect } from "react";
import { logError } from "@/lib/observability/logger";

export default function Error({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    logError(error, { route: "<this segment>" });
  }, [error]);

  return (
    <div role="alert">
      <h2>Something went wrong.</h2>
      <p>{error.message}</p>
      <button onClick={reset}>Try again</button>
    </div>
  );
}
```

Every segment-level `error.tsx` should follow this shape: log the error with route context, render a recovery action, accept the `reset` prop.

## The `digest` field

Next.js attaches a `digest` to server-side errors (a hash of the error for tracking). Always log the digest alongside the route — it's the only way to correlate a user-reported "I saw an error on the checkout page" with the actual stack trace in your observability tool.

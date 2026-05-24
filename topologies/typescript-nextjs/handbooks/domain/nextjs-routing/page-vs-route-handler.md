---
paths:
  - "app/**/page.tsx"
  - "app/**/route.ts"
  - "app/**/route.js"
---

# Handbook: page.tsx vs route.ts — pick the right boundary

**Scope:** PRs that touch Next.js App Router pages or route handlers.
**Enforcement:** advisory.

## The rule

Next.js App Router has two boundary types — `page.tsx` (renders HTML for a URL) and `route.ts` (returns a Response for a URL). They're not interchangeable. Pick by **what the URL is for**:

| If the URL... | Use | Returns |
|---|---|---|
| Renders a page (HTML, browser-navigable) | `page.tsx` | JSX (Server Component) |
| Returns JSON for a client / external consumer | `route.ts` | `NextResponse.json(...)` |
| Returns a file (CSV, PDF, image) | `route.ts` | `NextResponse(...)` with `Content-Type` header |
| Handles a webhook (Stripe, GitHub, etc.) | `route.ts` | `NextResponse(...)` with appropriate status |
| Serves a metadata file (`sitemap.xml`, `robots.txt`) | Special exports (`app/sitemap.ts`, `app/robots.ts`) | Next-handled types |
| Handles a form submission | **Server Action** (function in any server component, marked `"use server"`) | Anything; client sees a redirect or revalidation |

You can mix `page.tsx` and `route.ts` in the same segment — `app/orders/page.tsx` renders the order list page; `app/orders/route.ts` cannot exist (one HTTP boundary per path). But `app/api/orders/route.ts` (different path) is fine.

## Why

Mixing the two leads to predictable bugs:

1. **Putting JSON-returning logic in a `page.tsx`.** The page becomes "API-shaped" — clients have to scrape JSON out of an HTML stream. Search engines try to index it.
2. **Putting page rendering in a `route.ts`.** You lose RSC streaming, layout composition, error boundaries, and metadata generation.
3. **Putting form submissions in a `route.ts`** when a Server Action would do. The form has to hand-write the fetch + state-management dance; Server Actions handle it natively.

## What Rex flags

Surface a finding when:

1. A `page.tsx` returns a string of JSON or sets `Content-Type: application/json` — almost certainly should be a `route.ts`.
2. A `route.ts` GET handler returns HTML (`new Response('<html>...')` or `NextResponse('<...>', { headers: { 'Content-Type': 'text/html' } })`) — should be a `page.tsx` so it integrates with layouts.
3. A `route.ts` POST handler implements a form submission flow (reads `formData`, redirects on success) AND the form is internal (rendered by this same app) — convert to a Server Action.
4. A `page.tsx` AND a `route.ts` exist in the same segment AND target the same path — Next.js throws at build time; the diff should not include both.
5. A `route.ts` is used for an OG-image / metadata endpoint — should be `app/[slug]/opengraph-image.tsx` instead (Next 13.3+).

## Sample finding

> **Routing (page vs route)** — `app/api/dashboard/route.ts` returns HTML (`new Response('<div>...</div>', { headers: { 'Content-Type': 'text/html' } })`). This loses layout integration, error boundaries, and metadata. Convert to `app/dashboard/page.tsx`; if the previous JSON consumers need API access, keep `app/api/dashboard/route.ts` for them and have the page use the API client.
>
> **Routing (Server Action vs route)** — `app/api/contact/route.ts` handles a contact-form POST that's only called from `app/contact/page.tsx`. Convert to a Server Action: define `async function submitContact(formData: FormData) { "use server"; ... }` and pass it as `<form action={submitContact}>`. The route handler becomes unnecessary; client-side state is handled natively.

## What's NOT a violation

- A `route.ts` that returns a file download (CSV, PDF, image) — that's exactly what it's for.
- A `route.ts` POST that's a webhook handler (Stripe, GitHub) — external consumer, must stay a route.
- A `route.ts` GET that returns JSON for an external API consumer (third-party integration) — that's the right boundary.
- A `page.tsx` that uses `generateMetadata` to return a JSON-LD structured-data object embedded in `<script>` — that's metadata in HTML, not JSON in HTTP.

## Decision tree

```
Does the URL return content meant for a browser to render as HTML?
├── YES → page.tsx
│         (use layouts, metadata, error boundaries; lean on RSC)
└── NO  → Is it called only by this app's own forms / interactions?
          ├── YES → Server Action
          │         (defined as "use server" function; called via form action or transition)
          └── NO  → route.ts
                    (external API consumers, webhooks, file downloads)
```

## Naming note

When a `route.ts` lives under `app/api/`, that's a strong signal it's an external API. Keep that convention even though Next.js doesn't enforce it — operators reading the code use `app/api/` as the "this is the public API" marker.

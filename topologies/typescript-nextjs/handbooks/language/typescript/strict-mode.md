# Handbook: TypeScript Strict Mode (Next.js variant)

**Scope:** PRs touching `**/*.{ts,tsx}` files in a Next.js project (handbook lives under `language/typescript/` — Rex loads it only when the PR diff includes TypeScript files).
**Enforcement:** advisory.

## The rule

Every TypeScript project under ApexYard's Next.js topology enables strict mode AND `noUncheckedIndexedAccess`. The `tsconfig.json` MUST include:

```json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noFallthroughCasesInSwitch": true,
    "noImplicitOverride": true,
    "useUnknownInCatchVariables": true
  }
}
```

| Required | Why this matters in Next.js |
|---|---|
| `"strict": true` | Catches null/undefined, function-shape mismatches, uninitialised class fields — table-stakes for any TS project |
| `"noUncheckedIndexedAccess": true` | `params.id` from a Next.js route is typed as `string` by default; with this flag it's `string \| undefined`, which is closer to the truth (App Router params CAN be missing if the route is mis-configured) |
| `"noFallthroughCasesInSwitch": true` | Server Action discriminators frequently use switch statements over union types; fall-through bugs are silent failures |
| Avoid `any` without a justification comment | Inline `// any: <reason>` or `// @ts-expect-error` |
| Forbid `// @ts-ignore` | Use `// @ts-expect-error` so the suppression auto-errors when the underlying issue is fixed |

## Why

Next.js's runtime surface is wide: server components, client components, route handlers, middleware, Server Actions, generateStaticParams, generateMetadata. Each has its own typing quirks. Strict mode + `noUncheckedIndexedAccess` is the only way the type checker can pull its weight across all of them.

Without these flags, `app/[id]/page.tsx` accepting `{ params }` types `params.id` as `string` even though it can be `undefined` for malformed routes — and the type system silently agrees while production throws. Strict mode + `noUncheckedIndexedAccess` flips that to a compile error, which is exactly when you want to know.

## What Rex flags

Surface a finding when:

1. The PR adds OR modifies `tsconfig.json` AND any of the five settings above is missing or set to `false`.
2. A `.ts` / `.tsx` file in the diff contains bare `any` (function parameter, return type, variable annotation, `as any`) without an inline justification comment on the same or preceding line.
3. A `.ts` / `.tsx` file in the diff uses `// @ts-ignore`. Switch to `// @ts-expect-error`.
4. A Server Action or Route Handler uses `as` to cast `req.body` / `formData` without a runtime validation step (Zod, manual guards) immediately preceding it.
5. A `params` / `searchParams` access in `app/**/page.tsx` doesn't handle the `undefined` case (often a `params.id!` non-null assertion without explanation).

## Sample findings

> **Strict mode (NextJS)** — `tsconfig.json` is missing `noUncheckedIndexedAccess: true`. Without it, `params.id` in `app/[id]/page.tsx` is typed as `string`, but the actual value can be `undefined` for malformed routes. Add the flag and handle the undefined case.
>
> **Strict mode (NextJS)** — `app/api/orders/route.ts:18` casts `await req.json() as CreateOrderRequest` without validation. Use Zod to parse the body at the boundary: `const body = CreateOrderSchema.parse(await req.json())`.
>
> **Strict mode (NextJS)** — `app/dashboard/page.tsx:7` uses `params.id!` non-null assertion. Either handle the undefined case (return `notFound()`) or document why the assertion is safe with `// params.id is guaranteed by [id] segment` on the line above.

## What's NOT a violation

- `unknown` instead of `any` for catch variables — that's the safe alternative, encouraged by `useUnknownInCatchVariables`.
- `as` for narrowings AFTER a runtime check (`if ('field' in body) { const typed = body as Shape; }`).
- Generated code (`prisma/client/`, `next-env.d.ts`, OpenAPI codegen) — out of scope; flag the generator config if it produces too much `any`.
- `// @ts-expect-error` with a description (`// @ts-expect-error: Stripe types don't expose this field`).

## Recipe — fixing a bare `any`

If you spot bare `any`s in code you're already touching:

1. **Identify the shape at the use site.** Often it's a small union (`'pending' | 'shipped'`) or a domain type.
2. **For dynamic values, use `unknown` + narrow with a guard.**
3. **For HTTP boundaries (route handlers, form actions), use Zod.** Parse once at the boundary; the rest of the code holds a typed value.
4. **If the codebase has a value object that fits**, use it (`UserId` instead of `string`).

The first two are usually 30 seconds. The Zod boundary pattern takes 5 minutes and eliminates an entire class of "request shape changed and nobody noticed" bugs.

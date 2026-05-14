# Handbook: TypeScript Strict Mode

**Scope:** PRs touching `**/*.{ts,tsx}` files (handbook lives under `language/typescript/` — Rex loads it only when the PR diff includes TypeScript files).
**Enforcement:** advisory.

## The rule

All TypeScript projects under this organisation enable strict mode and avoid `any` without an inline justification.

| Required | Setting / pattern |
|---|---|
| `tsconfig.json` strict mode | `"strict": true` (which enables `strictNullChecks`, `noImplicitAny`, `strictFunctionTypes`, `strictBindCallApply`, `strictPropertyInitialization`, `noImplicitThis`, `alwaysStrict`) |
| Additional flags | `"noUncheckedIndexedAccess": true` (array access returns `T \| undefined`), `"noFallthroughCasesInSwitch": true` |
| `any` usage | Only with an inline `// @ts-expect-error` or `// any: <reason>` comment on the same or preceding line, justifying why a typed shape isn't possible |
| Type assertions (`as`) | Acceptable for narrowing union types after a runtime check; **not** acceptable as a way to silence a type error you don't understand |
| `// @ts-ignore` | Forbidden. Use `// @ts-expect-error` instead — it errors out when the underlying issue is fixed, surfacing dead suppressions. |

## Why

TypeScript's type system is opt-in by design — every escape hatch (`any`, `as`, `@ts-ignore`) silences the compiler without explaining why. Without a discipline against unjustified escape hatches, the codebase rots into "TypeScript-shaped JavaScript" — types in the IDE, runtime errors in production.

Strict mode catches the largest class of preventable bugs at compile time: accidental `null` / `undefined`, function-shape mismatches, uninitialised class fields. Once the project is on strict mode, *staying* on strict mode requires reviewers to push back on `any` (and friends) — that's what this handbook is for.

## What Rex flags

When reviewing a PR, surface a finding when:

1. The PR adds OR modifies a `tsconfig.json` AND the resulting effective config doesn't enable `strict: true`.
2. A `.ts` / `.tsx` file in the diff contains a bare `any` (function parameter, return type, variable annotation, type assertion `as any`) without an inline justification comment on the same or preceding line.
3. A `.ts` / `.tsx` file in the diff uses `// @ts-ignore` (use `// @ts-expect-error` instead).
4. A `.ts` / `.tsx` file in the diff uses `as` to narrow without a runtime check immediately preceding it. Heuristic: `as X` where `X` is a concrete type (not a union member after a `typeof`/`instanceof`/`in` check on the prior 1-3 lines).

## Sample findings

> **Strict mode** — `src/handlers/user.ts:42` declares `function fetchUser(id: any): Promise<User>`. The `id` parameter is implicitly stringly-typed; replace with `string` (or a `UserId` value object if one exists in the domain).
>
> **Strict mode** — `src/lib/parse.ts:18` uses `// @ts-ignore`. Switch to `// @ts-expect-error` so the compiler tells us when the suppression becomes obsolete.
>
> **Strict mode** — `src/api/order.ts:67` casts `req.body as CreateOrderRequest` without validating the shape. Add a runtime check (Zod / io-ts / hand-written guard) before the cast, or import a validated DTO from `domain/`.

## What's NOT a violation

- `any` with a clear inline justification: `function debug(x: any) { /* any: pretty-printer accepts arbitrary shapes */ console.dir(x) }`.
- `unknown` — the safe alternative to `any`. Encouraged for boundaries where the shape isn't known until runtime.
- `as` for genuinely safe narrowings: `const order = result as Order` *after* `if (result.kind === 'order')` etc.
- Generated code with `any` (e.g. OpenAPI codegen) — out of scope; flag the codegen config instead if it produces too much `any`.

## Refactor recipe

If you spot bare `any`s in code you're already touching:

1. Identify the shape the value actually has at the use site. Often it's a small union (`'pending' | 'shipped' | 'delivered'`) or a concrete domain type.
2. If the value is genuinely dynamic, use `unknown` and narrow with a guard.
3. If the boundary is external (HTTP body, message queue payload), define a Zod / io-ts schema and parse once at the boundary; the rest of the code holds a typed value.
4. If the codebase has a domain value object that fits, use it (e.g. `UserId` instead of `string`).

The first two are usually 30 seconds. The schema-at-boundary path takes 5 minutes per boundary but eliminates an entire class of "request shape changed and nobody noticed" bugs.

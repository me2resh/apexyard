# Handbook: Clean Code — Naming

**Scope:** all PRs (handbook lives under `general/` — Rex always loads it).
**Enforcement:** advisory.

## The rule

Names are the primary communication layer of code. Every identifier — variable, function, class, module, file — must answer "what is this?" without requiring the reader to trace execution.

| Identifier type | Rule | Good | Bad |
|---|---|---|---|
| Variable | Noun describing the data it holds | `discountAmount`, `activeUsers` | `x`, `d`, `temp`, `data` |
| Boolean variable | `is/has/can/should` prefix | `isActive`, `hasPermission`, `canRetry` | `active`, `flag`, `check` |
| Function | Verb + noun describing the action and subject | `calculateTotalWithTax`, `fetchUserById` | `ab`, `doStuff`, `process` |
| Class | PascalCase noun for the concept it models | `InvoiceRepository`, `StudentEnrollment` | `Mgr`, `Handler`, `Util` |
| Constant | SCREAMING_SNAKE_CASE for true constants | `MAX_RETRY_COUNT`, `DEFAULT_PAGE_SIZE` | `n`, `val`, `MAGIC_123` |
| Event handler | `handle` + event | `handleSubmit`, `handlePaymentFailed` | `click`, `onEvent`, `fn` |

**Single-letter names** are only acceptable for:
- Loop counters: `i`, `j`, `k`
- Well-understood math conventions in a clearly scoped block: `x`, `y` in a coordinate transform

**Abbreviations**: only use them if they are universally understood in the domain (`id`, `url`, `api`, `db`). Never invent abbreviations (`usrCnt`, `invItm`, `pmtAmt`).

**Case consistency**: pick one convention per identifier class and apply it uniformly across the entire file and module. Never mix `camelCase` and `snake_case` for the same kind of identifier in the same module.

## Why

Descriptive names eliminate the need to hold mental state while reading. When a reader sees `discountAmount` they know what it is, where it comes from, and roughly what values it takes. When they see `d` they must trace backwards. The cognitive load compounds — a function with 4 single-letter variables forces the reader to maintain a private symbol table in working memory throughout.

## What Rex flags

1. **Single-letter or two-letter variable names** outside of loop counters and math conventions (e.g. `let x = getUser()`, `const d = new Date()`).
2. **Meaningless generic names** — `data`, `result`, `temp`, `value`, `item`, `obj`, `info`, `stuff`, `thing`.
3. **Negated booleans** — `notActive`, `isNotValid`. Prefer `isInactive`, `isInvalid`.
4. **Function names with no verb** — `userData()`, `total()`, `list()`.
5. **Inconsistent casing** — a module using both `camelCase` and `snake_case` for variables of the same kind.
6. **Invented abbreviations** — `usrCnt`, `invItm`, `pmtAmt`.

## Sample findings

> **Naming** — `const d = await getUser(userId)` uses a single-letter variable. Rename to `user` so the reader doesn't need to scroll up to know what `d` represents.

> **Naming** — `function data()` has no verb. Rename to describe the action: `fetchDashboardData()`, `loadStudentData()`, etc.

> **Naming** — `isNotVerified` is a negated boolean. Prefer `isUnverified` so the positive case reads naturally: `if (isUnverified)` instead of `if (isNotVerified)`.

## What's NOT a violation

- `i`, `j`, `k` as loop indices.
- `e` as an event parameter in a short, immediately-used handler: `btn.addEventListener('click', e => e.preventDefault())`.
- `id`, `url`, `api`, `db`, `dto` — domain-standard abbreviations whose meaning is unambiguous.
- Short lambda parameters when the function is a one-liner and the type is clear from context: `users.filter(u => u.isActive)`.
- File names that are intentionally terse by convention: `index.ts`, `types.ts`, `utils.ts`.

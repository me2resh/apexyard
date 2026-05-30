# Handbook: Clean Code — Functions

**Scope:** all PRs (handbook lives under `general/` — Rex always loads it).
**Enforcement:** advisory.

## The rule

### Single Responsibility

Every function must do **one thing**. If you need "and" to describe what a function does, it does too much.

```ts
// Bad: two responsibilities — validation AND persistence
function saveUser(user: User) {
  if (!user.email.includes('@')) throw new Error('Invalid email')
  if (!user.name) throw new Error('Name required')
  db.insert('users', user)
  sendWelcomeEmail(user.email)
}

// Good: each function has one job
function validateUser(user: User): void {
  if (!user.email.includes('@')) throw new Error('Invalid email')
  if (!user.name) throw new Error('Name required')
}

function persistUser(user: User): void {
  db.insert('users', user)
}

function onboardUser(user: User): void {
  validateUser(user)
  persistUser(user)
  sendWelcomeEmail(user.email)
}
```

### Size

- Functions should fit in one screen (~20–30 lines). If they don't, extract sub-functions.
- Avoid deeply nested conditionals (>2 levels). Use early returns (guard clauses) to flatten nesting.

```ts
// Bad: 3 levels of nesting
function processOrder(order: Order) {
  if (order) {
    if (order.items.length > 0) {
      if (order.isPaid) {
        fulfillOrder(order)
      }
    }
  }
}

// Good: guard clauses
function processOrder(order: Order) {
  if (!order) return
  if (order.items.length === 0) return
  if (!order.isPaid) return
  fulfillOrder(order)
}
```

### Arguments

- Prefer **≤ 3 parameters**. More than 3 is a signal the function is doing too much, or that a parameter object is warranted.
- Use a named options object when parameters exceed 3 or when their order is non-obvious.
- Use rest parameters (`...args`) for genuinely variadic functions.

```ts
// Bad: 5 positional args — order is easy to mix up
function createInvoice(studentId, amount, dueDate, currency, notes) { ... }

// Good: named options object
function createInvoice({ studentId, amount, dueDate, currency, notes }: InvoiceOptions) { ... }
```

### Reusability

- Extract repeated logic into a shared function the moment it appears a second time.
- Never hardcode values that change between contexts — accept them as parameters or import from a single constants file.
- Functions that handle a class of inputs are more valuable than functions that handle one specific case.

### Consistent Style

Apply the same function declaration style within a module. If you use arrow functions for service methods, use them throughout. Mixing `function foo()` and `const foo = () =>` in the same file without a clear rule is noise.

## Why

Small, single-purpose functions are the unit of reuse. They are independently testable, independently readable, and independently replaceable. A function that does three things can only be tested as a bundle of three things — a bug anywhere forces you to understand all three before you can fix one.

Guard clauses eliminate the "Christmas tree" nesting pattern that forces readers to track indentation depth as a proxy for logic depth.

## What Rex flags

1. **Functions longer than ~40 lines** without an obvious structural reason (e.g. a long but flat switch/case).
2. **Nesting depth > 2** — three or more levels of `if`/`for`/`try` nested inside each other.
3. **Functions with > 3 positional parameters** not wrapped in an options object.
4. **Duplicated logic blocks** — the same 3+ line sequence appearing in two or more places without extraction.
5. **Functions described with "and" in a comment** — a clear signal of double responsibility.
6. **Hardcoded values** (magic numbers, magic strings) that should be constants or parameters.

## Sample findings

> **Function size** — `processEnrollment()` is 78 lines and handles validation, fee calculation, section assignment, and notification. Extract each concern into its own function (`validateEnrollmentRequest`, `calculateEnrollmentFee`, `assignStudentToSection`, `notifyEnrollmentSuccess`) and have `processEnrollment` orchestrate them.

> **Nesting depth** — Three levels of `if` nesting inside `handleAttendance()` makes the happy path hard to follow. Flatten with guard clauses: return early on each invalid condition and keep the main logic at the top level.

> **Hardcoded value** — `if (absences > 10)` on line 34 is a magic number. Extract to a named constant: `const MAX_ALLOWED_ABSENCES = 10`.

## What's NOT a violation

- A function that is long because it contains a flat, exhaustive `switch` statement or lookup table — length here is data, not complexity.
- A small utility lambda (1–3 lines) defined inline at the call site when it is used exactly once and extracting it would create more indirection than clarity.
- Two functions that share similar structure but operate on genuinely different data shapes — not every similarity is duplication.

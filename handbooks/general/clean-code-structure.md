# Handbook: Clean Code — Structure, Comments & Data

**Scope:** all PRs (handbook lives under `general/` — Rex always loads it).
**Enforcement:** advisory.

## The rule

### Comments — explain WHY, never WHAT

Code already shows WHAT it does. Comments exist for the WHY — the non-obvious constraint, the business rule, the workaround, the gotcha.

```ts
// Bad: restates the code
// increment the counter
counter++

// Bad: explains WHAT, which the code already shows
// filter active users from the list
const activeUsers = users.filter(u => u.isActive)

// Good: explains WHY — the rule that isn't obvious from the code
// students on academic probation are excluded from the honour roll
// even if their current GPA qualifies them (policy: Board resolution 2024-03)
const eligibleStudents = students.filter(s => !s.isOnProbation && s.gpa >= HONOUR_ROLL_GPA)
```

**Comment density**: a file where every other line has a comment is under-expressed in code, not well-documented. If you feel the need to explain WHAT, improve the name instead.

**Inline documentation** (JSDoc / TSDoc): required on public API surfaces — exported functions, service methods, and types consumed outside the module. Not required on internal helpers.

### Single Source of Truth

Configuration, thresholds, feature flags, and shared constants must live in **one place**. Duplication means divergence.

```ts
// Bad: the same value in two places
// invoiceService.ts
if (amount > 10000) requireManagerApproval()

// paymentService.ts
if (totalCharge > 10000) flagForReview()   // <-- will drift

// Good: one source
// constants/finance.ts
export const MANAGER_APPROVAL_THRESHOLD = 10_000

// invoiceService.ts + paymentService.ts both import from constants/finance.ts
```

### Data Exposure — expose only what is needed

Avoid passing entire objects when only a few fields are required. Use destructuring to make the dependency explicit. Hiding internal state protects the caller from implementation details and narrows the surface for bugs.

```ts
// Bad: passes the whole session object; callee depends on an invisible contract
function renderUserMenu(session: Session) {
  return `Hello, ${session.user.profile.displayName}`
}

// Good: callee only needs the name
function renderUserMenu({ displayName }: { displayName: string }) {
  return `Hello, ${displayName}`
}
```

### Folder / Module Structure

Organise by **feature**, not by file type.

```
// Bad: file-type organisation — forces cross-folder jumps for every feature
/components/StudentCard.tsx
/components/InvoiceCard.tsx
/services/studentService.ts
/services/invoiceService.ts

// Good: feature organisation — everything for a feature is co-located
/students/StudentCard.tsx
/students/studentService.ts
/invoices/InvoiceCard.tsx
/invoices/invoiceService.ts
```

Each module/folder should have a clear, bounded responsibility. If you cannot describe a module's purpose in one sentence without using "and", split it.

### Formatting Consistency

- Indentation, spacing, quote style, and semicolons are enforced by the project formatter (Prettier / ESLint). Run the formatter before committing — do not hand-format.
- Keep operator spacing consistent: `a + b`, not `a+b`.
- One blank line between logical sections within a function; two blank lines between top-level declarations.

## Why

**Comments**: stale comments that contradict the code are worse than no comments. Keeping them to the WHY ensures they remain accurate even when the code around them changes.

**Single source of truth**: every duplication is a future inconsistency. When a threshold changes in one place but not another, the bug is invisible until it hits production.

**Data exposure**: a function that depends on a whole object is implicitly coupled to every field of that object. Narrowing to only what's needed makes the dependency graph visible and reduces the blast radius of refactors.

**Feature-based structure**: when a developer works on the Student feature, they should be able to stay in one folder. File-type structure forces constant context-switching across the tree.

## What Rex flags

1. **WHAT comments** — comments that explain what the code does rather than why it does it (`// loop through users`, `// return the result`).
2. **Commented-out code** — dead code left as comments. Delete it; git history preserves it.
3. **Duplicated constants or thresholds** — the same magic number or string literal appearing in more than one file without a shared source.
4. **Whole-object parameter passing** when only 1–2 fields are used inside the function.
5. **Cross-module imports that break feature boundaries** — a finance module importing directly from an internal SIS helper instead of a shared interface.
6. **TODO comments older than one sprint** without a linked ticket — either create a ticket or remove the comment.

## Sample findings

> **Comment quality** — `// loop through students and calculate average` on line 45 describes WHAT the code does. The code already shows that. Remove the comment or replace it with WHY: e.g. `// weighted average required because elective subjects carry half the credit value`.

> **Commented-out code** — Lines 67–74 are commented out. If this code is no longer needed, delete it — git history preserves it. If it's needed conditionally, extract it behind a flag or a separate function.

> **Single source of truth** — The value `30` (representing the maximum absence threshold) appears on lines 12, 89, and 134 in three different files. Extract to `constants/attendance.ts` as `MAX_ABSENCES_BEFORE_ALERT = 30` and import from there.

> **Data exposure** — `generateReport(enrollment: Enrollment)` uses only `enrollment.studentId` and `enrollment.termId` inside the function body. Change the signature to `generateReport({ studentId, termId }: Pick<Enrollment, 'studentId' | 'termId'>)` to make the dependency explicit.

## What's NOT a violation

- Section-header comments in long files to aid navigation (`// --- Validation ---`, `// --- Persistence ---`) when the file cannot be reasonably split further.
- TODOs tied to a real open ticket: `// TODO(#234): replace with batch API when endpoint is ready`.
- JSDoc on exported public API functions — always welcome, never excessive.
- Commented-out code in a PR that explicitly removes the feature and keeps the comment temporarily as context during review — remove before merge.

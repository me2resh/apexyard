# Backspace — Decision Log

## Purpose

This document records durable product and technical decisions for Backspace so implementation can proceed without re-opening settled scope.

For the broader project context, read:

- `projects/backspace/README.md`
- `projects/backspace/PRD.md`
- `projects/backspace/TECHNICAL_DESIGN.md`
- `projects/backspace/SCREEN_SPECS.md`
- `projects/backspace/TEST_PLAN.md`

---

## Decision 1 — MVP is internal-only

**Status**: Accepted

Backspace MVP is an internal system for coworking-space owners, managers, and staff.

### Consequences

- No visitor/customer portal in v0.
- No customer login.
- No public booking page.
- No public payment page.
- Customers are internal records only.
- All pages except `/login` require staff authentication.

### Affected screens

- `/login`
- `/dashboard`
- `/spaces`
- `/customers`
- `/customers/:id`
- `/visits`
- `/visits/new`
- `/visits/:id`
- `/subscriptions`
- `/bookings`
- `/invoices`
- `/reports`
- `/settings/location`
- `/settings/staff`

---

## Decision 2 — Arabic RTL first

**Status**: Accepted

The MVP UI is Arabic-only and RTL.

### Consequences

- Root layout should use `lang="ar"` and `dir="rtl"`.
- All labels, validation messages, empty states, and navigation should be Arabic.
- No full i18n requirement in v0.
- UI QA must include RTL checks from `projects/backspace/SCREEN_SPECS.md` and `projects/backspace/TEST_PLAN.md`.

---

## Decision 3 — One location in MVP, reusable later

**Status**: Accepted

Backspace launches for one coworking-space location first, but should be reusable later under another name/brand.

### Consequences

- No full multi-tenant architecture in v0.
- No multi-location admin in v0.
- Branding and invoice prefix must live in `location_settings`.
- Business logic should not hardcode the Backspace name.

---

## Decision 4 — Stack is Next.js + PostgreSQL

**Status**: Accepted

Backspace implementation stack:

- Next.js App Router
- TypeScript
- PostgreSQL
- Modular monolith

### Consequences

- Use server-side authorization for all privileged actions.
- Keep modules explicit and domain-oriented.
- Use PostgreSQL relational constraints where practical.
- Keep the implementation aligned with `projects/backspace/API_CONTRACTS.md` and `projects/backspace/PRISMA_SCHEMA_DRAFT.md`.

---

## Decision 5 — Prisma as default ORM

**Status**: Accepted as default

Use Prisma for MVP database models and migrations unless implementation constraints force a change.

### Consequences

- Start with `StaffUser` and `LocationSettings` in Sprint 1.
- Add remaining models sprint-by-sprint.
- Use `projects/backspace/PRISMA_SCHEMA_DRAFT.md` as the implementation starting point.

---

## Decision 6 — Session-based staff auth

**Status**: Accepted as default

Backspace uses staff-only session authentication.

### Consequences

- `StaffUser.passwordHash` stores password hashes only.
- `StaffUser.isActive` blocks disabled staff.
- No customer auth tables are needed.
- Session validation should also check staff is still active.
- Generic Arabic login errors should avoid account enumeration.

---

## Decision 7 — Daily visits bill hourly with rounding

**Status**: Accepted for MVP

Daily visits are billed with:

- Minimum billable duration: 1 hour.
- After 1 hour: round up to nearest 30 minutes.

### Examples

| Actual duration | Billable duration |
|---|---:|
| 20 minutes | 1 hour |
| 59 minutes | 1 hour |
| 70 minutes | 1.5 hours |
| 91 minutes | 2 hours |

### Consequences

- `Visit.hourlyRateSnapshot` must be stored at check-in.
- `Visit.totalAmount` is calculated at checkout.
- Calculation requires unit tests in `projects/backspace/TEST_PLAN.md`.

---

## Decision 8 — Subscription durations

**Status**: Accepted for MVP

Supported subscriptions:

- Weekly = 7 days.
- Biweekly = 14 days.
- Monthly = 30 days.

### Consequences

- `SubscriptionPlan.durationDays` is derived from `durationType`.
- `CustomerSubscription.endDate` is calculated at creation.
- `CustomerSubscription.priceSnapshot` is stored.

---

## Decision 9 — Manual payments only in v0

**Status**: Accepted

Backspace MVP records manual payments only.

### Payment methods

- Cash
- Bank transfer
- External card
- Other

### Consequences

- No online payment gateway in v0.
- No public payment page.
- Payment recording is staff-only.
- Cancelled invoices reject payments.

---

## Decision 10 — Booking conflict prevention is P0

**Status**: Accepted

Confirmed bookings for the same space must not overlap.

### Conflict rule

```text
new.startsAt < existing.endsAt
AND new.endsAt > existing.startsAt
AND existing.status = confirmed
AND existing.spaceId = new.spaceId
```

### Consequences

- Adjacent bookings are allowed.
- Cancelled bookings do not block availability.
- Conflict detection needs integration tests.

---

## Decision 11 — Financial visibility is role-restricted

**Status**: Accepted

Owner and Manager can see full financial dashboard/reporting. Staff can operate daily workflows but cannot see full financial totals.

### Consequences

- `/dashboard` must be role-aware.
- `/reports` must block payment reports for Staff.
- Server-side authorization is required.

---

## Open Decisions

These remain unresolved before or during implementation:

1. Deployment target: Vercel, VPS, Docker, or other.
2. Package manager: npm, pnpm, yarn, or bun.
3. Exact session storage mechanism.
4. PDF invoices: v0 or P1.
5. CSV/Excel export: v0 or P1.
6. Whether customer phone should be unique in v0.
7. Whether partial payments are fully supported in v0 or treated as P1.

---

## Decision Review Trigger

Revisit this decision log if any of the following changes:

- The product becomes customer-facing.
- Multi-location support becomes required for MVP.
- Online payments move into v0.
- The stack changes away from Next.js + PostgreSQL.
- Arabic-only UI changes to bilingual/i18n in v0.

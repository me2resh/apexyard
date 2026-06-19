# Backspace — Test Plan

## Purpose

This document defines the MVP test strategy for Backspace, the internal Arabic RTL coworking-space management app.

It complements:

- `projects/backspace/README.md`
- `projects/backspace/SCREEN_SPECS.md`
- `projects/backspace/QA_CHECKLIST.md`
- `projects/backspace/API_CONTRACTS.md`
- `projects/backspace/PRISMA_SCHEMA_DRAFT.md`

---

## Test Strategy

Backspace should use layered tests:

1. Unit tests for business calculations and permission helpers.
2. Integration tests for database-backed workflows.
3. API/server action tests for validation and authorization.
4. E2E smoke tests for the most important staff flows.
5. Manual QA checklist before launch.

Recommended default from implementation docs:

- Vitest for unit/integration tests.
- Playwright later for E2E smoke/hardening.

---

## Critical Business Rules to Test

### Authentication

- `StaffUser.passwordHash` is used for verification.
- Raw passwords are never stored.
- `StaffUser.isActive = false` blocks login.
- Sessions are required for every internal route.
- Customers never authenticate.

### Permissions

- Owner can update `LocationSettings`.
- Manager/Staff cannot update `LocationSettings` in v0.
- Staff cannot manage spaces.
- Staff cannot create/cancel subscriptions.
- Staff cannot cancel invoices.
- Staff cannot see full financial dashboard/report data.

### Visits

- Check-in requires active customer and active space.
- `hourlyRateSnapshot` is stored at check-in.
- Check-out calculates duration and total.
- Minimum billable duration is one hour.
- After one hour, billable duration rounds up to nearest 30 minutes.

### Subscriptions

- Weekly = 7 days.
- Biweekly = 14 days.
- Monthly = 30 days.
- `priceSnapshot` is preserved.
- Archived customers and inactive plans are rejected.

### Bookings

- Confirmed bookings cannot overlap for the same space.
- Adjacent bookings are allowed.
- Cancelled bookings do not block availability.

### Billing

- Invoice numbers use `LocationSettings.invoicePrefix`.
- Open visits cannot be invoiced.
- Duplicate invoice for same non-manual source is blocked.
- Cancelled invoices reject payments.
- Full payment marks invoice paid.

---

## Unit Test Matrix

| Area | Test Cases |
|---|---|
| Visit billing | 20m → 1h, 59m → 1h, 70m → 1.5h, 91m → 2h |
| Subscription dates | weekly +7, biweekly +14, monthly +30 |
| Booking overlap | overlap rejected, adjacent allowed, cancelled ignored |
| Payment totals | full payment marks paid, cancelled rejects payment |
| Permissions | role helper allows/denies expected actions |
| Invoice numbering | prefix applied, number unique format generated |

---

## Integration Test Matrix

### Sprint 1 — Auth + Settings

- Active Owner can log in.
- Disabled staff cannot log in.
- `GET /api/auth/me` returns current staff user.
- Owner can update `LocationSettings`.
- Staff cannot update `LocationSettings`.

### Sprint 2 — Spaces + Customers

- Owner/Manager can create and deactivate spaces.
- Staff can view spaces but not create them.
- Staff can create and edit customers.
- Staff cannot archive customers.
- Archived customers are hidden by default.

### Sprint 3 — Visits

- Staff can create open visit.
- Check-in fails for archived customer.
- Check-in fails for inactive space.
- Staff can close open visit.
- Closed visit stores `durationMinutes` and `totalAmount`.
- Owner/Manager edits create audit log entries.

### Sprint 4 — Subscriptions

- Owner/Manager can create plans.
- Staff cannot create plans.
- Owner/Manager can create customer subscriptions.
- Staff cannot create subscriptions.
- `endDate` and `priceSnapshot` are correct.

### Sprint 5 — Bookings

- Staff can create booking.
- Conflict detection rejects overlap.
- Adjacent bookings are allowed.
- Cancelled booking does not block availability.

### Sprint 6 — Billing

- Closed visit can be invoiced.
- Open visit cannot be invoiced.
- Full payment marks invoice paid.
- Cancelled invoice rejects payment.
- Staff cannot cancel invoice.

### Sprint 7 — Dashboard + Reports

- Owner/Manager can view revenue widgets.
- Staff cannot view revenue widgets.
- Payments report is blocked for Staff.
- Dashboard excludes cancelled invoices from unpaid/revenue calculations.

---

## E2E Smoke Tests

These should be added after Sprint 6 or during Sprint 8 hardening.

### Smoke 1 — Owner setup

1. Owner opens `/login`.
2. Owner logs in.
3. Owner lands on `/dashboard`.
4. Owner opens `/settings/location`.
5. Owner updates location name and invoice prefix.

Expected:

- UI is Arabic RTL.
- Settings save successfully.
- Updated location name appears in app shell.

### Smoke 2 — Customer daily visit

1. Staff logs in.
2. Staff opens `/customers`.
3. Staff creates customer.
4. Staff opens `/visits/new`.
5. Staff starts visit.
6. Staff opens `/visits/:id`.
7. Staff checks out visit.

Expected:

- Visit closes.
- Duration and total are calculated.
- Customer profile at `/customers/:id` shows the visit.

### Smoke 3 — Booking conflict

1. Staff opens `/bookings`.
2. Staff creates confirmed booking.
3. Staff attempts overlapping booking for the same space.

Expected:

- Conflict is rejected.
- Arabic error is shown.

### Smoke 4 — Subscription and invoice

1. Manager opens `/subscriptions`.
2. Manager creates weekly plan.
3. Manager adds customer subscription.
4. Staff creates invoice.
5. Staff registers payment.

Expected:

- Subscription dates are correct.
- Invoice becomes paid after full payment.

### Smoke 5 — Staff financial restriction

1. Staff logs in.
2. Staff opens `/dashboard`.
3. Staff opens `/reports`.

Expected:

- Full revenue widgets are hidden.
- Payment report is inaccessible.

---

## Arabic RTL QA

Run visual/manual checks on:

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
- `/invoices/:id`
- `/reports`
- `/settings/location`
- `/settings/staff`

Check:

- Page direction is RTL.
- Tables are readable.
- Forms align correctly.
- Dialogs are RTL.
- Arabic validation copy appears.
- Currency and dates are understandable.

---

## Launch Test Gate

Do not launch if any of these fail:

- Unauthenticated users can access internal pages.
- Staff can access Owner-only settings.
- Staff can see full financial dashboard/report data.
- Customer/visitor-facing login or portal exists.
- Visit billing calculation is wrong.
- Booking conflicts are possible.
- Raw passwords are stored or logged.
- Invoices or payments can enter inconsistent states.

---

## CI Recommendation

Every PR should run:

```bash
npm run lint
npm run typecheck
npm test
npm run build
```

Before launch, also run E2E smoke tests if Playwright is configured.

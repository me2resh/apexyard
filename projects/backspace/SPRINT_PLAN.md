# Backspace — MVP Sprint Plan

## Overview

This plan breaks the Backspace internal coworking management MVP into implementation sprints. The project is Arabic RTL, internal-only, and starts with one location while remaining reusable/white-label-ready later.

---

## Sprint 0 — Project Setup

**Goal:** Prepare the technical foundation.

### Scope

- Create web app project.
- Configure database.
- Configure migrations/ORM.
- Configure Arabic RTL theme/app shell.
- Prepare auth/session foundation.
- Prepare seed mechanism.

### Done When

- App boots successfully.
- Database connection works.
- First migration runs.
- Login page placeholder exists.
- RTL layout foundation is present.

---

## Sprint 1 — Staff Auth + Location Settings

**Goal:** Owner can log in and configure the single location.

### Tables

- `staff_users`
- `location_settings`

### APIs

- `POST /api/auth/login`
- `POST /api/auth/logout`
- `GET /api/auth/me`
- `GET /api/settings/location`
- `PATCH /api/settings/location`

### Screens

- `/login`
- `/dashboard` placeholder
- `/settings/location`

### Key Rules

- `passwordHash` stores hashed passwords only.
- `isActive = false` blocks login.
- Owner can update `location_settings`.
- Staff/Manager cannot update `location_settings` in v0.

### Done When

- Active owner can log in.
- Disabled user cannot log in.
- Protected pages require session.
- Location settings can be updated by Owner.

---

## Sprint 2 — Spaces + Customers

**Goal:** Staff can manage core operational records.

### Tables

- `spaces`
- `customers`

### APIs

- `GET /api/spaces`
- `POST /api/spaces`
- `PATCH /api/spaces/:id`
- `PATCH /api/spaces/:id/deactivate`
- `GET /api/customers`
- `POST /api/customers`
- `GET /api/customers/:id`
- `PATCH /api/customers/:id`
- `PATCH /api/customers/:id/archive`

### Screens

- `/spaces`
- `/customers`
- `/customers/:id`

### Done When

- Owner/Manager can manage spaces.
- Staff can view spaces.
- Staff can create/edit customers.
- Owner/Manager can archive customers.
- No customer login exists.

---

## Sprint 3 — Daily Hourly Visits

**Goal:** Staff can run check-in/check-out and calculate visit cost.

### Tables

- `visits`
- `audit_logs` begins being used for sensitive changes

### APIs

- `GET /api/visits`
- `POST /api/visits/check-in`
- `POST /api/visits/:id/check-out`
- `PATCH /api/visits/:id`
- `PATCH /api/visits/:id/cancel`

### Screens

- `/visits`
- `/visits/new`
- `/visits/:id`

### Key Rules

- Check-in requires active customer and active space.
- Save `hourlyRateSnapshot` at check-in.
- Checkout calculates duration and total amount.
- Minimum billable time = 1 hour; then round up to nearest 30 minutes.
- Staff cannot edit closed visits.

### Done When

- Staff can create and close visits.
- Visit calculation tests pass.
- Closed visit edits by Owner/Manager write audit logs.

---

## Sprint 4 — Subscriptions

**Goal:** Managers can create plans and assign subscriptions to customers.

### Tables

- `subscription_plans`
- `customer_subscriptions`

### APIs

- `GET /api/subscription-plans`
- `POST /api/subscription-plans`
- `PATCH /api/subscription-plans/:id`
- `GET /api/subscriptions`
- `POST /api/subscriptions`
- `PATCH /api/subscriptions/:id/cancel`

### Screens

- `/subscriptions`
- customer detail subscription section

### Key Rules

- weekly = 7 days.
- biweekly = 14 days.
- monthly = 30 days.
- Save `priceSnapshot`.
- End date calculated automatically.

### Done When

- Owner/Manager can create weekly, biweekly, and monthly plans.
- Owner/Manager can create/cancel customer subscriptions.
- Staff can read subscriptions only.

---

## Sprint 5 — Internal Bookings

**Goal:** Staff can create bookings without schedule conflicts.

### Tables

- `bookings`

### APIs

- `GET /api/bookings`
- `GET /api/bookings/availability`
- `POST /api/bookings`
- `PATCH /api/bookings/:id`
- `PATCH /api/bookings/:id/cancel`

### Screens

- `/bookings`
- `/bookings/new` or modal
- customer detail booking section

### Key Rules

- Confirmed bookings cannot overlap for the same space.
- Cancelled bookings do not block availability.
- Adjacent bookings are allowed.

### Done When

- Staff can create/cancel bookings.
- Conflict prevention works.
- Availability endpoint reports conflicts.

---

## Sprint 6 — Invoices + Manual Payments

**Goal:** Staff can create invoices and record manual payments.

### Tables

- `invoices`
- `payments`

### APIs

- `GET /api/invoices`
- `POST /api/invoices`
- `GET /api/invoices/:id`
- `PATCH /api/invoices/:id/cancel`
- `POST /api/payments`
- `GET /api/invoices/:id/payments`

### Screens

- `/invoices`
- `/invoices/:id`
- payment modal
- customer financial history section

### Key Rules

- Invoice numbers use `location_settings.invoicePrefix`.
- Manual payments only; no payment gateway.
- Full payment marks invoice paid.
- Cancelled invoices reject new payments.
- Staff cannot cancel invoices.

### Done When

- Invoices work for visits, subscriptions, bookings/manual charges.
- Payments can be registered.
- Customer billing history is visible.

---

## Sprint 7 — Dashboard + Reports

**Goal:** Owner/Manager gets operational and financial visibility.

### APIs

- `GET /api/dashboard/today`
- `GET /api/dashboard/revenue`
- `GET /api/dashboard/expiring-subscriptions`
- `GET /api/dashboard/unpaid-invoices`
- `GET /api/dashboard/occupancy`
- `GET /api/reports/visits`
- `GET /api/reports/payments`
- `GET /api/reports/subscriptions`
- `GET /api/reports/bookings`

### Screens

- `/dashboard`
- `/reports`

### Key Rules

- Owner/Manager can see financial widgets.
- Staff sees operational dashboard only.
- Revenue is based on `payments.amount`, not invoice totals alone.
- Cancelled invoices are excluded.

### Done When

- Role-aware dashboard works.
- Reports support date/status filters.
- Staff cannot access payment reports or full revenue widgets.

---

## Sprint 8 — QA + Hardening

**Goal:** Verify the MVP is ready for internal launch.

### Focus Areas

- Auth/session security.
- Role permissions.
- Arabic RTL consistency.
- Internal-only boundary.
- Visit calculation.
- Subscription expiry.
- Booking conflicts.
- Invoice/payment integrity.
- Audit logs for sensitive changes.

### Done When

- Full QA checklist passes.
- No visitor/customer-facing pages exist.
- All internal pages require auth/session.
- Launch acceptance criteria are met.

---

## Dependency Graph

```text
Sprint 0
  ↓
Sprint 1: staff_users + location_settings
  ↓
Sprint 2: spaces + customers
  ↓
Sprint 3: visits
  ├── Sprint 4: subscriptions
  ├── Sprint 5: bookings
  └── Sprint 6: invoices/payments
          ↓
Sprint 7: dashboard/reports
          ↓
Sprint 8: QA/hardening
```

---

## First Implementation Package

Start with:

1. Project setup.
2. Arabic RTL app shell.
3. `staff_users` migration.
4. `location_settings` migration.
5. Owner seed account.
6. Login/logout/me APIs.
7. Location settings API.
8. `/login`, `/dashboard`, `/settings/location`.

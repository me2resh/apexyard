# Backspace — Draft Tracker Issues

## Purpose

This file prepares draft tracker issues for Backspace without filing them yet.

Use this after the implementation repository exists and Backspace is added to `apexyard.projects.yaml`.

> These are draft tracker issues. They are not real GitHub issues until created in the selected repo.

---

## Labels to Create

Recommended labels:

- `backspace`
- `mvp`
- `foundation`
- `auth`
- `settings`
- `operations`
- `visits`
- `subscriptions`
- `bookings`
- `billing`
- `dashboard`
- `reports`
- `qa`
- `security`
- `arabic-rtl`

---

## Milestones to Create

1. Backspace M0 — Foundation
2. Backspace M1 — Secure Internal Access
3. Backspace M2 — Operations Records
4. Backspace M3 — Daily Visits
5. Backspace M4 — Subscriptions
6. Backspace M5 — Bookings
7. Backspace M6 — Billing
8. Backspace M7 — Dashboard & Reports
9. Backspace M8 — QA & Launch Hardening

---

## Draft Issue 1 — Create Next.js project skeleton

**Backlog ID**: `BSP-FOUND-001`  
**Milestone**: Backspace M0 — Foundation  
**Labels**: `backspace`, `mvp`, `foundation`, `arabic-rtl`

### Summary

Create the Backspace implementation app using Next.js, TypeScript, Tailwind CSS, and App Router.

### Scope

- Run `create-next-app` for the Backspace app.
- Configure TypeScript.
- Configure Tailwind CSS.
- Configure ESLint.
- Add initial README with local setup instructions.
- Add base project scripts.

### Acceptance Criteria

- App runs locally.
- `npm run lint` exists.
- `npm run typecheck` exists or is added.
- Test command exists.
- README documents local setup.
- No customer/visitor-facing route exists.

---

## Draft Issue 2 — Configure PostgreSQL and Prisma migrations

**Backlog ID**: `BSP-FOUND-002`  
**Milestone**: Backspace M0 — Foundation  
**Labels**: `backspace`, `mvp`, `foundation`

### Summary

Configure local PostgreSQL and Prisma migration tooling.

### Scope

- Add Prisma.
- Add Prisma client.
- Configure PostgreSQL datasource.
- Add Docker Compose PostgreSQL setup.
- Add `.env.example` with placeholders only.
- Document migration commands.

### Acceptance Criteria

- Local database starts with Docker Compose.
- Prisma connects to PostgreSQL.
- First empty or initial migration runs.
- `.env.example` contains no real secrets.
- `.env` is ignored.

---

## Draft Issue 3 — Build Arabic RTL app shell

**Backlog ID**: `BSP-FOUND-003`  
**Milestone**: Backspace M0 — Foundation  
**Labels**: `backspace`, `mvp`, `foundation`, `arabic-rtl`

### Summary

Create the internal Arabic RTL app shell that all future screens use.

### Scope

- Set root HTML to Arabic RTL.
- Add authenticated-app shell placeholder.
- Add Arabic navigation labels.
- Add initial dashboard placeholder.
- Initialize shadcn/ui components if not already done.

### Acceptance Criteria

- Root layout uses `lang="ar"` and `dir="rtl"`.
- Navigation is Arabic.
- Layout is suitable for internal admin pages.
- No public customer/visitor navigation exists.

---

## Draft Issue 4 — Add staff user model and owner seed

**Backlog ID**: `BSP-AUTH-001`  
**Milestone**: Backspace M1 — Secure Internal Access  
**Labels**: `backspace`, `mvp`, `auth`, `security`

### Summary

Add the internal `StaffUser` model and safe initial Owner seeding.

### Scope

- Add `StaffUser` Prisma model.
- Include `passwordHash`, `role`, and `isActive`.
- Add owner seed script.
- Read initial owner credential from local environment only.

### Acceptance Criteria

- `StaffUser` table exists.
- `email` is unique.
- Passwords are stored only as `passwordHash`.
- `isActive` exists and defaults appropriately.
- Seed script does not log raw credentials.

---

## Draft Issue 5 — Implement staff login, logout, and session

**Backlog ID**: `BSP-AUTH-002`  
**Milestone**: Backspace M1 — Secure Internal Access  
**Labels**: `backspace`, `mvp`, `auth`, `security`

### Summary

Implement staff-only authentication and session protection.

### Scope

- Implement staff login.
- Implement logout.
- Implement current-user lookup.
- Protect internal routes.
- Enforce `isActive` during login and session validation.

### Acceptance Criteria

- Active Owner can log in.
- Wrong credentials fail with a generic Arabic error.
- Disabled staff cannot log in.
- Internal pages require a session.
- Customer records cannot authenticate.

---

## Draft Issue 6 — Implement location settings

**Backlog ID**: `BSP-AUTH-003`  
**Milestone**: Backspace M1 — Secure Internal Access  
**Labels**: `backspace`, `mvp`, `settings`, `arabic-rtl`

### Summary

Implement single-location settings for branding and invoice data.

### Scope

- Add `LocationSettings` model.
- Build read/update server logic.
- Build `/settings/location` page.
- Use settings in app shell where relevant.

### Acceptance Criteria

- Owner can update location name, logo, address, phone, currency, invoice prefix, and tax number.
- Manager/Staff cannot update location settings in v0.
- App branding reads from `LocationSettings`.
- Backspace branding is not hardcoded into business logic.

---

## Draft Issue 7 — Implement spaces management

**Backlog ID**: `BSP-OPS-001`  
**Milestone**: Backspace M2 — Operations Records  
**Labels**: `backspace`, `mvp`, `operations`

### Summary

Allow Owner/Manager to manage coworking spaces and hourly rates.

### Scope

- Add `Space` model.
- Build spaces list.
- Build create/edit/deactivate flows.
- Enforce role permissions.

### Acceptance Criteria

- Owner/Manager can create, edit, and deactivate spaces.
- Staff can view spaces only.
- Validation covers name, type, capacity, and hourly rate.
- Deactivated spaces remain stored with `isActive = false`.

---

## Draft Issue 8 — Implement internal customer records

**Backlog ID**: `BSP-OPS-002`  
**Milestone**: Backspace M2 — Operations Records  
**Labels**: `backspace`, `mvp`, `operations`

### Summary

Implement internal customer records with no customer login.

### Scope

- Add `Customer` model.
- Build customer list.
- Build create/edit forms.
- Build customer detail page.
- Add archive flow for Owner/Manager.

### Acceptance Criteria

- Staff can create and edit customers.
- Customers have no login/session.
- Customer type supports visitor, subscriber, company.
- Staff cannot archive customers.
- Customer detail has placeholders for future history sections.

---

## Draft Issue 9 — Implement visit check-in

**Backlog ID**: `BSP-VISIT-001`  
**Milestone**: Backspace M3 — Daily Visits  
**Labels**: `backspace`, `mvp`, `visits`

### Summary

Implement hourly visit check-in for active customers and spaces.

### Scope

- Add `Visit` model.
- Build check-in flow.
- Store `hourlyRateSnapshot`.
- Show open visits.

### Acceptance Criteria

- Staff can start a visit.
- Archived customers are rejected.
- Inactive spaces are rejected.
- `hourlyRateSnapshot` is copied from the selected space.

---

## Draft Issue 10 — Implement visit check-out and calculation

**Backlog ID**: `BSP-VISIT-002`  
**Milestone**: Backspace M3 — Daily Visits  
**Labels**: `backspace`, `mvp`, `visits`, `billing`

### Summary

Implement check-out with duration and total cost calculation.

### Scope

- Close open visits.
- Calculate `durationMinutes`.
- Calculate `totalAmount`.
- Apply billable rounding rule.

### Acceptance Criteria

- Minimum billable duration is 1 hour.
- After 1 hour, billable duration rounds up to nearest 30 minutes.
- Total uses `hourlyRateSnapshot`.
- Closed visit cannot be checked out again.

---

## Draft Issue 11 — Implement subscription plans

**Backlog ID**: `BSP-SUB-001`  
**Milestone**: Backspace M4 — Subscriptions  
**Labels**: `backspace`, `mvp`, `subscriptions`

### Summary

Implement subscription plan management for weekly, biweekly, and monthly plans.

### Acceptance Criteria

- Weekly maps to 7 days.
- Biweekly maps to 14 days.
- Monthly maps to 30 days.
- Owner/Manager can manage plans.
- Staff can read plans only.

---

## Draft Issue 12 — Implement customer subscriptions

**Backlog ID**: `BSP-SUB-002`  
**Milestone**: Backspace M4 — Subscriptions  
**Labels**: `backspace`, `mvp`, `subscriptions`

### Summary

Allow Owner/Manager to assign subscriptions to customers.

### Acceptance Criteria

- End date is calculated from plan duration.
- `priceSnapshot` is stored.
- Archived customers are rejected.
- Inactive plans are rejected.
- Staff cannot create/cancel subscriptions.

---

## Draft Issue 13 — Implement bookings CRUD

**Backlog ID**: `BSP-BOOK-001`  
**Milestone**: Backspace M5 — Bookings  
**Labels**: `backspace`, `mvp`, `bookings`

### Summary

Implement staff-created internal bookings.

### Acceptance Criteria

- Staff can create bookings for active customers and spaces.
- Booking requires `endsAt > startsAt`.
- Cancelled bookings remain in history.
- Customer detail shows bookings.

---

## Draft Issue 14 — Implement booking conflict prevention

**Backlog ID**: `BSP-BOOK-002`  
**Milestone**: Backspace M5 — Bookings  
**Labels**: `backspace`, `mvp`, `bookings`

### Summary

Prevent overlapping confirmed bookings for the same space.

### Acceptance Criteria

- Overlapping confirmed booking is rejected.
- Adjacent bookings are allowed.
- Cancelled bookings do not block availability.
- Error message is Arabic and clear.

---

## Draft Issue 15 — Implement invoices

**Backlog ID**: `BSP-BILL-001`  
**Milestone**: Backspace M6 — Billing  
**Labels**: `backspace`, `mvp`, `billing`

### Summary

Create invoices for visits, subscriptions, bookings, and manual charges.

### Acceptance Criteria

- Invoice numbers use `location_settings.invoicePrefix`.
- Invoice numbers are unique.
- Closed visits can be invoiced.
- Open visits cannot be invoiced.
- Duplicate invoices for the same source are blocked.

---

## Draft Issue 16 — Implement manual payments

**Backlog ID**: `BSP-BILL-002`  
**Milestone**: Backspace M6 — Billing  
**Labels**: `backspace`, `mvp`, `billing`

### Summary

Record manual payments against invoices.

### Acceptance Criteria

- Payment amount must be greater than zero.
- Payment methods include cash, bank transfer, external card, other.
- Full payment marks invoice as paid.
- Cancelled invoices reject payment.
- Payment stores the receiving staff user.

---

## Draft Issue 17 — Implement role-aware dashboard

**Backlog ID**: `BSP-DASH-001`  
**Milestone**: Backspace M7 — Dashboard & Reports  
**Labels**: `backspace`, `mvp`, `dashboard`

### Summary

Implement dashboard widgets for operations and restricted financial visibility.

### Acceptance Criteria

- Dashboard shows open visits, today visits, upcoming bookings, and expiring subscriptions.
- Owner/Manager see revenue widgets.
- Staff do not see full revenue widgets.
- Occupancy ignores inactive spaces.

---

## Draft Issue 18 — Implement basic reports

**Backlog ID**: `BSP-DASH-002`  
**Milestone**: Backspace M7 — Dashboard & Reports  
**Labels**: `backspace`, `mvp`, `reports`

### Summary

Implement basic visits, payments, subscriptions, and bookings reports.

### Acceptance Criteria

- Visits report filters by date and space.
- Payments report is blocked for Staff.
- Payments report uses `payments.amount`.
- Subscription and booking reports filter correctly.

---

## Draft Issue 19 — Run full MVP QA matrix

**Backlog ID**: `BSP-QA-001`  
**Milestone**: Backspace M8 — QA & Launch Hardening  
**Labels**: `backspace`, `mvp`, `qa`, `arabic-rtl`

### Summary

Run the MVP QA checklist across all core flows.

### Acceptance Criteria

- All P0 QA checks pass.
- Arabic RTL is verified across pages.
- No visitor/customer-facing product exists.
- All internal pages require session.

---

## Draft Issue 20 — Security and data integrity hardening

**Backlog ID**: `BSP-QA-002`  
**Milestone**: Backspace M8 — QA & Launch Hardening  
**Labels**: `backspace`, `mvp`, `qa`, `security`

### Summary

Harden auth, permissions, financial changes, and data integrity.

### Acceptance Criteria

- No raw passwords are stored.
- `isActive` is enforced.
- Role checks are server-side.
- Sensitive financial changes are traceable.
- `hourlyRateSnapshot` and `priceSnapshot` are preserved.

---

## Filing Order

Recommended order when creating real tracker issues:

1. File all M0/M1 issues first.
2. Start implementation with foundation and auth.
3. File remaining milestones before their work begins, or file all drafts at once if the team wants full visibility.

Do not mark these as real tracker items until they are created in GitHub.

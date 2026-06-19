# Backspace — Implementation Backlog

This backlog translates the approved PRD, technical design, sprint plan, and QA checklist into implementation-ready work items.

> Note: These are planning backlog items, not tracker issues. Convert them into GitHub issues only when the team is ready to execute.

---

## Item ID Convention

- `BSP-FOUND-*` — foundation
- `BSP-AUTH-*` — authentication and settings
- `BSP-OPS-*` — spaces and customers
- `BSP-VISIT-*` — daily visits
- `BSP-SUB-*` — subscriptions
- `BSP-BOOK-*` — bookings
- `BSP-BILL-*` — billing
- `BSP-DASH-*` — dashboard and reports
- `BSP-QA-*` — QA and hardening

---

## Sprint 0 — Project Setup

### BSP-FOUND-001 — Create web app skeleton

**Priority:** P0  
**Depends on:** None

**Scope**

- Create the application repository/project structure.
- Configure runtime, package manager, linting, formatting, and test runner.
- Add initial README with local setup steps.

**Acceptance Criteria**

- App starts locally.
- Test command runs.
- Lint/typecheck command exists.
- README documents local development.

### BSP-FOUND-002 — Configure database and migrations

**Priority:** P0  
**Depends on:** BSP-FOUND-001

**Scope**

- Configure database connection.
- Configure migrations.
- Add migration command documentation.

**Acceptance Criteria**

- Database connects locally.
- Empty initial migration runs successfully.
- Migrations can be reset in development.

### BSP-FOUND-003 — Build Arabic RTL app shell

**Priority:** P0  
**Depends on:** BSP-FOUND-001

**Scope**

- Add base layout.
- Configure RTL direction.
- Add Arabic navigation labels.
- Create protected-app shell placeholder.

**Acceptance Criteria**

- UI renders right-to-left.
- Navigation labels are Arabic.
- No public customer-facing navigation exists.

---

## Sprint 1 — Staff Auth + Location Settings

### BSP-AUTH-001 — Add staff user model and owner seed

**Priority:** P0  
**Depends on:** BSP-FOUND-002

**Scope**

- Add `staff_users` migration.
- Include `passwordHash`, `role`, and `isActive`.
- Create initial owner seed path.

**Acceptance Criteria**

- `staff_users` table exists.
- Passwords are stored only as `passwordHash`.
- Owner seed account can be created securely.
- `isActive` defaults correctly.

### BSP-AUTH-002 — Implement staff login/logout/session

**Priority:** P0  
**Depends on:** BSP-AUTH-001

**Scope**

- Implement login.
- Implement logout.
- Implement current-user endpoint.
- Protect internal routes.

**Acceptance Criteria**

- Active owner can log in.
- Wrong credentials fail with generic Arabic error.
- `isActive = false` blocks login.
- Unauthenticated access is rejected or redirected.

### BSP-AUTH-003 — Implement location settings

**Priority:** P0  
**Depends on:** BSP-AUTH-002

**Scope**

- Add `location_settings` migration.
- Implement read/update API.
- Build `/settings/location` screen.

**Acceptance Criteria**

- Owner can update location name, phone, address, logo, currency, invoice prefix, and tax number.
- Manager/Staff cannot update settings.
- App branding reads from `location_settings`.

---

## Sprint 2 — Spaces + Customers

### BSP-OPS-001 — Implement spaces management

**Priority:** P0  
**Depends on:** BSP-AUTH-002

**Scope**

- Add `spaces` table.
- Build spaces list and create/edit forms.
- Add deactivate flow.

**Acceptance Criteria**

- Owner/Manager can create, edit, and deactivate spaces.
- Staff can view spaces only.
- Validation covers name, type, capacity, and hourly rate.
- Deactivated spaces are preserved with `isActive = false`.

### BSP-OPS-002 — Implement customer records

**Priority:** P0  
**Depends on:** BSP-AUTH-002

**Scope**

- Add `customers` table.
- Build customers list, create/edit forms, and detail page.
- Add archive flow.

**Acceptance Criteria**

- Staff can create and edit customers.
- Owner/Manager can archive customers.
- Staff cannot archive customers.
- Customers have no login/session.
- Customer detail page has placeholders for visits, subscriptions, bookings, and billing history.

---

## Sprint 3 — Daily Visits

### BSP-VISIT-001 — Implement visit check-in

**Priority:** P0  
**Depends on:** BSP-OPS-001, BSP-OPS-002

**Scope**

- Add `visits` table.
- Build check-in API and UI.
- Store `hourlyRateSnapshot`.

**Acceptance Criteria**

- Staff can start a visit for active customer and active space.
- Archived customers are rejected.
- Inactive spaces are rejected.
- Open visits appear in visits screen.

### BSP-VISIT-002 — Implement visit check-out and calculation

**Priority:** P0  
**Depends on:** BSP-VISIT-001

**Scope**

- Build check-out flow.
- Calculate `durationMinutes` and `totalAmount`.
- Apply billing rounding rule.

**Acceptance Criteria**

- Minimum billable duration is 1 hour.
- After 1 hour, duration rounds up to nearest 30 minutes.
- Total uses `hourlyRateSnapshot`.
- Closed visit cannot be checked out again.

### BSP-VISIT-003 — Add visit corrections and audit logging

**Priority:** P1  
**Depends on:** BSP-VISIT-002

**Scope**

- Add `audit_logs` table if not already added.
- Allow Owner/Manager to edit/cancel visits.
- Record sensitive changes.

**Acceptance Criteria**

- Staff cannot edit closed visits.
- Owner/Manager can correct visits.
- Closed visit edits create audit log entries.

---

## Sprint 4 — Subscriptions

### BSP-SUB-001 — Implement subscription plans

**Priority:** P0  
**Depends on:** BSP-OPS-002

**Scope**

- Add `subscription_plans` table.
- Build plans API and management UI.

**Acceptance Criteria**

- Weekly plan maps to 7 days.
- Biweekly plan maps to 14 days.
- Monthly plan maps to 30 days.
- Owner/Manager can manage plans.
- Staff can read plans only.

### BSP-SUB-002 — Implement customer subscriptions

**Priority:** P0  
**Depends on:** BSP-SUB-001

**Scope**

- Add `customer_subscriptions` table.
- Build create/cancel subscription flow.
- Show subscriptions on customer detail.

**Acceptance Criteria**

- End date is calculated from plan duration.
- `priceSnapshot` is stored.
- Archived customers are rejected.
- Inactive plans are rejected.
- Staff cannot create/cancel subscriptions.

---

## Sprint 5 — Internal Bookings

### BSP-BOOK-001 — Implement bookings CRUD

**Priority:** P0  
**Depends on:** BSP-OPS-001, BSP-OPS-002

**Scope**

- Add `bookings` table.
- Build bookings list and create/edit/cancel flows.

**Acceptance Criteria**

- Staff can create bookings for active customers and spaces.
- Booking requires `endsAt > startsAt`.
- Cancelled bookings remain in history.
- Customer detail shows bookings.

### BSP-BOOK-002 — Implement booking availability and conflict prevention

**Priority:** P0  
**Depends on:** BSP-BOOK-001

**Scope**

- Implement availability endpoint.
- Prevent overlapping confirmed bookings for same space.

**Acceptance Criteria**

- Overlapping confirmed booking is rejected.
- Adjacent bookings are allowed.
- Cancelled bookings do not block availability.
- Error message is Arabic and clear.

---

## Sprint 6 — Invoices + Manual Payments

### BSP-BILL-001 — Implement invoices

**Priority:** P0  
**Depends on:** BSP-AUTH-003, BSP-VISIT-002, BSP-SUB-002, BSP-BOOK-001

**Scope**

- Add `invoices` table.
- Create invoices for visits, subscriptions, bookings/manual charges.
- Generate invoice number from `location_settings.invoicePrefix`.

**Acceptance Criteria**

- Invoice numbers are unique.
- Closed visit can be invoiced.
- Open visit cannot be invoiced.
- Duplicate invoice for same source is blocked.
- Staff cannot cancel invoices.

### BSP-BILL-002 — Implement manual payments

**Priority:** P0  
**Depends on:** BSP-BILL-001

**Scope**

- Add `payments` table.
- Build payment registration flow.
- Update invoice status when paid.

**Acceptance Criteria**

- Payment amount must be greater than zero.
- Methods include cash, bank transfer, external card, other.
- Full payment marks invoice as paid.
- Cancelled invoice rejects payment.
- Payment stores `receivedByStaffId`.

---

## Sprint 7 — Dashboard + Reports

### BSP-DASH-001 — Implement role-aware dashboard

**Priority:** P0  
**Depends on:** BSP-VISIT-002, BSP-SUB-002, BSP-BOOK-002, BSP-BILL-002

**Scope**

- Build dashboard summary APIs.
- Build owner/manager dashboard widgets.
- Build restricted staff dashboard widgets.

**Acceptance Criteria**

- Dashboard shows open visits, today visits, upcoming bookings, and expiring subscriptions.
- Owner/Manager see revenue widgets.
- Staff do not see full revenue widgets.
- Occupancy ignores inactive spaces.

### BSP-DASH-002 — Implement basic reports

**Priority:** P1  
**Depends on:** BSP-DASH-001

**Scope**

- Add reports for visits, payments, subscriptions, and bookings.
- Add filters by date/status/entity where relevant.

**Acceptance Criteria**

- Visits report filters by date and space.
- Payments report is blocked for Staff.
- Payments report uses `payments.amount`.
- Subscription and booking reports filter correctly.

---

## Sprint 8 — QA + Hardening

### BSP-QA-001 — Run full MVP acceptance matrix

**Priority:** P0  
**Depends on:** All P0 items

**Scope**

- Execute the QA checklist.
- Verify role permissions.
- Verify Arabic RTL.
- Verify internal-only boundary.

**Acceptance Criteria**

- All P0 QA checks pass.
- No visitor/customer-facing product exists.
- All internal pages require session.

### BSP-QA-002 — Security and data integrity hardening

**Priority:** P0  
**Depends on:** All P0 items

**Scope**

- Verify password/session safety.
- Verify server-side permissions.
- Verify financial auditability.
- Verify data snapshots.

**Acceptance Criteria**

- No raw passwords.
- `isActive` enforced.
- Sensitive financial changes are traceable.
- `hourlyRateSnapshot` and `priceSnapshot` are preserved.

---

## Recommended First Execution Batch

Start with these items:

1. BSP-FOUND-001
2. BSP-FOUND-002
3. BSP-FOUND-003
4. BSP-AUTH-001
5. BSP-AUTH-002
6. BSP-AUTH-003

This produces the first usable internal shell with staff login and configurable workspace settings.

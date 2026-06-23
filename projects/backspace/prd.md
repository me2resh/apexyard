# PRD: Backspace Workspace Operations Management System

**Status**: Draft
**Author**: ApexYard Product Manager / OpenCode
**Created**: 2026-06-23
**Last Updated**: 2026-06-23

---

## Overview

### Problem Statement

Coworking/workspace staff need one fast internal console for daily operations: arrivals, visits, space use, add-on charges, checkout, internal payments, cleaning, maintenance, memberships, tenants, events, and reporting. The current generated app is a technical foundation only; it needs a domain model and staff workflow that match physical workspace operations.

Standalone POS would create operational gaps because add-on sales must be traceable to a visitor, session, event, host, or invoice. Backspace must make Visit the operational source of truth and attach every sale-like action to the relevant operational context.

### Target User

**Primary**: Workspace staff: receptionist, cashier, supervisor, manager, cleaner, maintenance, admin/owner.

**Secondary**: Business operators reviewing revenue, occupancy, receivables, cleaning load, maintenance blocks, and audit activity.

### Goals

1. Staff can check in every physical visitor and maintain an auditable Visit record.
2. Billable space use is tracked through Usage Sessions with availability and double-booking protection.
3. Add-ons, services, manual fees, discounts, and complimentary items are captured as Charges attached to operational targets, not standalone anonymous POS sales.
4. Checkout reliably generates invoices, records internal payments, closes visits/sessions, and updates space state.
5. Managers can enforce permissions, shifts, audit logs, paid-invoice immutability, and reporting.

### Non-Goals (Out of Scope)

- Customer portal, customer self-service booking, or public checkout.
- External payment processing, payment-provider SDKs, webhooks, or settlement integrations.
- Replacing TanStack Router, Hono, tRPC, Better Auth, Drizzle, PostgreSQL, pnpm, or Vite+.
- Standalone POS as the normal daily sales workflow.
- Deployment setup in the first implementation cycle.

### Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| Staff check-in coverage | 100% of physical entrants have Visit records in seed/demo workflows | Visit records and workflow tests |
| Checkout integrity | Usage, add-ons, billing splits, payments, and space status update in one server-enforced flow | Integration tests and seed scenario QA |
| Billing traceability | 100% of charges link to visit/session/event/host/invoice draft | Database constraints/tests |
| Operational speed | Common staff actions happen from Today, Space Map, or drawers without deep navigation | UX review and manual QA |
| Governance | Restricted actions require permission and write audit logs | Permission tests and audit log assertions |

---

## User Stories

### US-1: Staff Check In Walk-In Visitor

> As a receptionist, I want to quickly create or find a person and create a Visit so that every physical visitor is logged and workspace use can start cleanly.

**Acceptance Criteria**:

- [ ] Staff can search by phone/name and quick-create a person.
- [ ] Staff can choose `walk_in` and billable or non-billable intent.
- [ ] Billable space use creates a Usage Session.
- [ ] Occupied space becomes unavailable for other check-ins.
- [ ] Visit creation is audited.

### US-2: Staff Check In Member

> As a receptionist, I want to validate an active membership during check-in so that included usage is applied and only uncovered usage or add-ons are billed.

**Acceptance Criteria**:

- [ ] Active, expired, frozen, suspended, and cancelled memberships are handled distinctly.
- [ ] Subscription coverage is calculated server-side.
- [ ] Included items remain auditable as zero-due records.
- [ ] Overage and add-ons are charged normally.

### US-3: Staff Check In Booking Customer

> As a receptionist, I want to open an upcoming booking and check the customer in so that calendar reservations become live usage sessions without double booking.

**Acceptance Criteria**:

- [ ] Booking status, time window, deposit/payment state, capacity, buffers, and space readiness are validated.
- [ ] Booking moves to `checked_in` on successful check-in.
- [ ] Visit and Usage Session are created from booking context.
- [ ] Conflicts block check-in with clear staff-facing errors.

### US-4: Staff Check In Hosted Guest

> As a receptionist, I want to link a guest visit to a host tenant/company/member so that host policies and billing responsibility are enforced.

**Acceptance Criteria**:

- [ ] Staff can choose host tenant/account/person.
- [ ] Host guest policy and credit limit are validated.
- [ ] Charges support visitor-paid, host-paid, included, complimentary, and pay-later responsibilities.
- [ ] Checkout can generate visitor invoice, host receivable, or no immediate payment.

### US-5: Staff Check In Event Attendee

> As event staff, I want attendee visits linked to events so that event capacity, guest-list rules, included items, and settlement are traceable.

**Acceptance Criteria**:

- [ ] Event guest-list mode and capacity are enforced.
- [ ] Event attendee check-in creates a Visit linked to the event.
- [ ] Included event items can be recorded as zero-price included charges.
- [ ] Attendee-paid, host-paid, event-paid, mixed, complimentary, and included billing are supported.

### US-6: Staff Add Charges Without POS

> As a cashier, I want to add products, printing, services, room extras, manual fees, discounts, or complimentary items to an existing operational target so that all sale-like activity is contextual and auditable.

**Acceptance Criteria**:

- [ ] Charge target is required: visit, usage session, event, host account, or invoice draft.
- [ ] Out-of-stock tracked catalog items cannot be added.
- [ ] Manual price override and high discounts require permission or approval.
- [ ] Complimentary charges require a reason.
- [ ] Finalized charges cannot be deleted directly.

### US-7: Staff Checkout Visit

> As a cashier, I want checkout to calculate usage, add-ons, discounts, tax, responsibility split, invoices, and payments so that the visit closes correctly and space state changes automatically.

**Acceptance Criteria**:

- [ ] Checkout calculates session usage, overtime, subscription coverage, and all charges server-side.
- [ ] Responsibilities split into separate invoices or allocations.
- [ ] Cash payment requires an open shift.
- [ ] Paid invoices are immutable.
- [ ] Space becomes cleaning, maintenance, or available based on rules.

### US-8: Manager Oversees Operations

> As a manager, I want dashboards, reports, approvals, and audit logs so that daily performance, exceptions, and sensitive changes are visible.

**Acceptance Criteria**:

- [ ] Today dashboard shows occupancy, active visits, upcoming bookings, overdue sessions, open bills, revenue, cleaning, maintenance, expiring memberships, and approvals.
- [ ] Daily, occupancy, and revenue reports summarize operational state.
- [ ] Sensitive actions require permissions and write audit logs.
- [ ] UI hides or disables unauthorized actions with explanation.

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | Register branches, floors, spaces, and state history | Must | Branch-aware operations |
| FR-2 | Manage people, customer accounts, tenants, plans, memberships, bookings, visits, usage sessions, events, hosted guests | Must | Core operating model |
| FR-3 | Enforce Visit-first operations for every physical entrant | Must | Not every Visit is billable |
| FR-4 | Enforce no standalone anonymous POS as the normal flow | Must | Use Charges/Add-ons attached to targets |
| FR-5 | Store and calculate money in integer minor units | Must | No JS floats for money |
| FR-6 | Add roles and permissions on top of Better Auth | Must | Server-enforced |
| FR-7 | Add tRPC routers for every domain area | Must | Thin routers, server business services |
| FR-8 | Add staff console shell with sidebar, topbar, branch selector, shift badge, search, quick actions | Must | Fast reception workflow |
| FR-9 | Implement Today, Live Visits, Space Map, Calendar, People, Billing, Shifts, Catalog, Inventory, Workspace, Events, Reports, Admin routes | Must | TanStack Router |
| FR-10 | Generate invoices and internal payment records without external payment provider | Must | cash/card_terminal/wallet/bank_transfer/instapay/mixed/pay_later/host_account |
| FR-11 | Require open shift for cash payments | Must | Cash control |
| FR-12 | Make paid/finalized invoices immutable and use corrections for changes | Must | Adjustment/refund/reversal path |
| FR-13 | Prevent double booking and invalid check-ins | Must | Server-side availability |
| FR-14 | Seed realistic data across all requested scenarios | Must | Enables QA and demo |
| FR-15 | Add reports for daily operations, occupancy, and revenue | Should | Manager view |
| FR-16 | Add global search and command shell | Should | Use existing shadcn first, add `cmdk` only if needed |
| FR-17 | Keep rich UI operational and dependency-gated | Must | Optional tools only when a ticket needs them: `motion`, `cmdk`, `@tanstack/react-table`, `recharts`, `@dnd-kit/*`, `dotLottie` |

**Priority Key**: Must (required for launch) | Should (important) | Could (nice to have)

### Non-Functional Requirements

| Category | Requirement | Target |
|----------|-------------|--------|
| Security | Authenticated staff-only access | Better Auth protected routes/procedures |
| Authorization | Restricted actions hidden/disabled in UI and enforced server-side | Permission middleware and tests |
| Auditability | Sensitive operations write audit logs | Actor, action, entity, before/after, reason |
| Performance | Reception workflows avoid deep navigation | Drawers, searchable tables, strong status badges |
| Reliability | Critical business rules are server-side | tRPC procedures and domain services |
| Financial integrity | Integer minor-unit money calculations | Helper module and tests |
| Accessibility | Restricted/disabled actions explain why | Tooltip or inline message |
| Interaction quality | Rich UI improves staff speed, feedback, and state clarity | Forms, tables, drawers, command/search, and reports are designed for operations density |

---

## Design

### Core User Flow

```text
Arrival
  -> Staff creates/opens Visit
  -> Optional Usage Session if occupying space
  -> Charges/Add-ons attached during stay
  -> Checkout drawer
  -> Billing responsibility split
  -> Invoice generation
  -> Internal payment record or receivable/pay-later
  -> Close Visit and Session
  -> Update space status and cleaning/maintenance tasks
```

### Staff Console Layout

Sidebar groups:

- Operations: Today, Live Visits, Space Map, Calendar, Check-in Queue.
- People: People, Members, Tenants, Event Guests.
- Billing: Open Bills, Invoices, Payments, Shifts.
- Add-ons & Inventory: Catalog, Inventory, Stock Movements.
- Workspace: Spaces, Cleaning, Maintenance.
- Events: Events, Guest Lists.
- Reports: Daily Report, Occupancy, Revenue.
- Admin: Staff & Roles, Settings, Audit Log.

Topbar:

- Branch selector.
- Current shift badge.
- Global search command.
- Quick actions: New Walk-in, Check-in Booking, Check-in Guest, Add Charge, Open/Close Shift.
- Notifications.
- Current user menu.

Reusable components:

- AppShell, Sidebar, Topbar, BranchSelector, ShiftStatusBadge, GlobalSearchCommand, PermissionGate.
- PageHeader, DataTable, FilterBar, StatusBadge, MoneyText, DateTimeText.
- DrawerForm, ConfirmActionDialog, PersonSearch, PersonQuickCreateForm.
- VisitStatusBadge, SpaceMap, SpaceStateLegend, SpaceDetailsDrawer.
- NewVisitDrawer, BookingDrawer, CheckInDrawer, VisitDetailsDrawer.
- AddChargeDrawer, CheckoutDrawer, PaymentPanel, ChargeList, InvoiceSummary.
- ApprovalBanner, AuditTimeline, CleaningQueue, MaintenanceTicketDrawer.

Interaction rules:

- Complex forms use TanStack Form plus Zod-derived validation. Drawers use progressive disclosure and precise inline errors where staff can act on them.
- Complex operational tables use `@tanstack/react-table` when sorting, filtering, column visibility, row selection, pagination, or bulk actions become real requirements.
- TanStack Query/tRPC owns server-state reads, mutations, cache invalidation, stale-state handling, and mutation feedback.
- `motion`, `cmdk`, `@tanstack/react-table`, `recharts`, `@dnd-kit/*`, and `dotLottie` are allowed only when a specific ticket justifies them. They are not baseline dependencies.
- Avoid marketing effects, 3D/parallax, carousel-heavy UI, vanity charts, and decorative animation.

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|------------|------|--------|-------|
| Existing Better-T-Stack monorepo | Internal | Ready | Engineering |
| Better Auth generated schema | Internal | Ready, extend carefully | Engineering |
| Drizzle schema expansion | Internal | Started via issue #4 / PR #21; remaining domain helpers and seeds still planned | Backend |
| TanStack Router route tree | Internal | Ready, extend | Frontend |
| shadcn/ui components in `packages/ui` | Internal | Ready, add missing components as needed | Frontend |
| Optional interaction/table/chart/date/money/report/calendar libs | External | Add only when ticket requires and PR explains why | Engineering |

### Technical Constraints

- Preserve generated conventions and package boundaries.
- Keep Hono as backend host and tRPC as typed API.
- Keep Better Auth as authentication base.
- Keep Drizzle + PostgreSQL as persistence layer.
- Use TanStack Router for routes.
- Use TanStack Form for complex forms.
- Use TanStack Query/tRPC for server state and mutation feedback.
- Use shadcn/ui components first before adding UI libraries.
- Add optional interaction/data-viz libraries only when the active ticket needs them and the PR explains why.

---

## Launch Plan

### Rollout Strategy

- [ ] Internal staff alpha with seeded/demo data.
- [ ] Operations MVP for receptionist/cashier/supervisor workflows.
- [ ] Billing and shift control hardening.
- [ ] Management reports and admin controls.
- [ ] QA on all acceptance scenarios before any real operational use.

---

## Open Questions

| Question | Owner | Status | Resolution |
|----------|-------|--------|------------|
| Inventory movement timing: charge finalization or invoice finalization? | Tech Lead/Product | Open | Recommendation: invoice finalization |
| Discount threshold that requires approval | Product/Manager | Open | TBD |
| Default branch currency/timezone | Product | Open | TBD |
| Quick Sale Visit shortcut allowed? | Product | Open | TBD |
| Event settlement representation | Tech Lead/Product | Open | TBD |

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| PRD Approved | TBD | Draft |
| Domain Foundation | TBD | In progress: schema complete via #4 / PR #21; #5-#7 remain open |
| App Shell | TBD | Filed as #8 |
| Operations MVP | TBD | Filed as #9-#14 |
| Billing Foundation | TBD | Filed as #14-#15 |
| People/Tenants/Events | TBD | Filed as #16-#18 |
| Inventory/Cleaning/Maintenance | TBD | Filed as #19 |
| Reports/Admin | TBD | Filed as #20 plus #5 for role infrastructure |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | TBD | | Pending |
| Head of Product | TBD | | Pending |
| Tech Lead | TBD | | Pending |
| Head of Design | TBD | | Pending |

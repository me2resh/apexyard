# Technical Design: Backspace Workspace Operations Management

**Status**: Draft
**Author**: ApexYard Tech Lead / OpenCode
**Date**: 2026-06-23
**PRD**: `projects/backspace/prd.md`
**Initiative**: `projects/backspace/initiatives/workspace-operations-management.md`

---

## Overview

### Summary

Backspace will extend the existing Better-T-Stack monorepo into a staff-only workspace operations console. The design preserves the generated stack and adds a Visit-first domain model, tRPC procedures, Drizzle schema modules, and TanStack Router staff workflows.

The core operational rule is that every physical entrant creates a Visit, billable space use creates a Usage Session, sales-like activity becomes target-bound Charges/Add-ons, and checkout converts the operational state into invoices, internal payments, and space-state updates.

### Goals

- Preserve the generated monorepo, package boundaries, and stack choices.
- Make Visit the operational source of truth for arrivals and physical presence.
- Keep Charges contextual: visit, session, event, host account, tenant, or invoice draft.
- Enforce money, permission, audit, invoice immutability, availability, and shift rules server-side.
- Provide a fast staff console for reception, cashier, manager, cleaner, maintenance, and admin roles.

### Non-Goals

- No new app scaffold and no stack replacement.
- No customer-facing portal or self-service booking in the first cycle.
- No external payment provider, payment SDK, or webhook integration.
- No standalone anonymous POS as the normal operating model.
- No deployment platform setup in the planning package.

---

## Domain Model

### Entities

| Area | Entity | Purpose | Notes |
|------|--------|---------|-------|
| Workspace | `Branch` | Physical location boundary | Default branch context for staff actions. |
| Workspace | `Floor` | Branch floor/zone grouping | Optional but useful for space maps. |
| Workspace | `Space` | Desk, room, office, seat, or area | Status drives availability. |
| Workspace | `SpaceStatusHistory` | Audit trail of status changes | Required for cleaning/maintenance transitions. |
| People | `Person` | Visitor, member, attendee, staff-linked human | Search by name/phone/email where available. |
| People | `CustomerAccount` | Billing profile for people/companies | Supports pay-later and host billing. |
| People | `Tenant` | Company or tenant host account | Owns hosted guest policy and receivables. |
| Membership | `MembershipPlan` | Plan definition | Included usage/items and constraints. |
| Membership | `Membership` | Person/account subscription | Status-aware coverage. |
| Scheduling | `Booking` | Reserved future usage | Converts to Visit/Usage Session on check-in. |
| Daily Ops | `Visit` | Physical presence record | Created for every entrant. |
| Daily Ops | `UsageSession` | Space occupation during a Visit | Billable or covered. |
| Daily Ops | `HostedGuestLink` | Guest-to-host relationship | Enforces host policy. |
| Events | `Event` | Event hosted in workspace | Has capacity, included items, settlement mode. |
| Events | `EventAttendee` | Attendee record and check-in state | Links event attendance to Visit. |
| Catalog | `CatalogItem` | Product/service/add-on/manual charge template | Can be tracked or non-tracked. |
| Catalog | `InventoryMovement` | Stock movement ledger | Timing open decision: invoice finalization recommended. |
| Billing | `Charge` | Contextual sale-like line | Must have exactly one operational target. |
| Billing | `Invoice` | Financial document grouped by responsibility | Finalized/paid invoices immutable. |
| Billing | `InvoiceItem` | Snapshot of charge into invoice | Avoids later catalog drift. |
| Billing | `Payment` | Internal payment record | No processor integration. |
| Billing | `RefundOrAdjustment` | Correction path | No direct mutation of finalized invoices. |
| Cash Control | `Shift` | Cashier shift window | Cash payments require open shift. |
| Facilities | `CleaningTask` | Space readiness task | Usually created after checkout. |
| Facilities | `MaintenanceTicket` | Space issue and block state | Can block check-in. |
| Staff | `StaffProfile` | App staff profile linked to Better Auth user | Adds role/branch scope. |
| Staff | `Role` | Permission bundle | Receptionist, cashier, supervisor, manager, cleaner, maintenance, admin/owner. |
| Staff | `Permission` | Server action capability | Checked in tRPC middleware/domain services. |
| Governance | `ApprovalRequest` | Sensitive-action approval | Discount/override/void/complementary as configured. |
| Governance | `AuditLog` | Sensitive action log | Actor, branch, entity, before/after, reason. |

### Value Objects

| Value Object | Fields | Purpose |
|--------------|--------|---------|
| `Money` | `amountMinor`, `currency` | Integer minor-unit calculations only. |
| `TimeRange` | `startsAt`, `endsAt`, `timezone` | Booking/session overlap checks. |
| `BranchScope` | `branchId`, `roleId`, `permissions[]` | Restrict staff actions by location and role. |
| `VisitType` | enum | `walk_in`, `member`, `booking_customer`, `hosted_guest`, `event_attendee`, `non_billable`. |
| `BillingResponsibility` | enum | `visitor_pays`, `host_pays`, `company_pays`, `event_pays`, `subscription_included`, `complimentary`, `pay_later`. |
| `PaymentMethod` | enum | `cash`, `card_terminal`, `wallet`, `bank_transfer`, `instapay`, `mixed`, `pay_later`, `host_account`. |
| `SpaceStatus` | enum | `available`, `occupied`, `reserved`, `cleaning`, `maintenance`, `blocked`, `inactive`. |
| `InvoiceStatus` | enum | `draft`, `finalized`, `paid`, `partially_paid`, `voided`, `refunded`. |
| `ApprovalPolicy` | `action`, `threshold`, `requiredPermission` | Decides when sensitive changes need supervisor approval. |

### Domain Events

| Event | Trigger | Data |
|-------|---------|------|
| `VisitCreated` | Staff checks in any entrant | visit, branch, person, type, actor. |
| `UsageSessionStarted` | Visit occupies a space | session, space, start time, billing context. |
| `ChargeAdded` | Staff adds contextual charge | charge, target, amount, responsibility, actor. |
| `CheckoutCalculated` | Staff opens checkout | visit/session, usage totals, charges, coverage, split. |
| `InvoiceFinalized` | Checkout creates financial records | invoice, items, totals, responsibility. |
| `PaymentRecorded` | Staff records internal payment | payment, method, amount, shift if cash. |
| `SpaceStateChanged` | Check-in/checkout/facilities action | space, old status, new status, reason. |
| `ApprovalRequested` | Discount/override/void crosses policy | request, action, actor, approver role. |
| `AuditLogWritten` | Sensitive operation committed | actor, entity, action, before/after, reason. |

---

## Architecture

### Document Set

| Artefact | Path | Purpose |
|----------|------|---------|
| Project map | `projects/backspace/PROJECT_MAP.md` | Persistent source of truth for repo and target modules. |
| Architecture vision | `projects/backspace/architecture/vision.md` | Target state, migration path, anti-scope. |
| C4 context | `projects/backspace/architecture/context.md` | As-is/top-level actors and system boundary. |
| C4 container | `projects/backspace/architecture/container.md` | Existing runnable units and planned domain layering. |
| DFD | `projects/backspace/architecture/dfd.md` | Trust boundaries and data classifications. |
| Sequence | `projects/backspace/architecture/sequence-visit-checkout.md` | Time-ordered visit-to-checkout flow. |
| Journey preview | `projects/backspace/journeys/workspace-operations.html` | Clickable flow preview before build. |

### Package Plan

Keep the generated Better-T-Stack layout and extend it by domain:

```text
apps/web
  TanStack Router staff routes and staff console components

apps/server
  Hono entrypoint, Better Auth handler, CORS, evlog, tRPC mount

packages/api
  tRPC router composition, protected procedures, permission middleware,
  domain services, validation schemas, audit and money helpers

packages/auth
  Better Auth setup, unchanged authentication base

packages/db
  Drizzle schema modules, migrations, seed data, Postgres docker setup

packages/ui
  shared shadcn/ui primitives and exported design-system components
```

### Layering Rules

- tRPC routers stay thin: parse input, check auth/permission, call a domain service, return DTOs.
- Domain services own invariants and transaction boundaries.
- Drizzle schema modules group tables by domain but export through `packages/db/src/schema/index.ts`.
- Better Auth tables remain in `auth.ts`; staff roles/profile tables are additive.
- UI authorization is convenience only. Server-side permission checks are authoritative.
- Money calculations never use floating-point amounts.

### Frontend Interaction Policy

Rich interaction in Backspace means operational clarity: staff can see state, act quickly, recover from conflicts, and understand why an action is unavailable. It does not mean decorative motion or marketing-grade effects.

| Area | Technical Direction |
|------|---------------------|
| Routes | Use TanStack Router for staff route groups, protected layouts, and route-level context. |
| Server state | Use TanStack Query with tRPC for queries, mutations, invalidation, stale-state handling, optimistic/pending states only where safe. |
| Forms | Use TanStack Form and Zod-backed schemas for check-in, add-charge, checkout, shift, booking, people, and settings forms. Prefer drawers and progressive disclosure for repeated staff workflows. |
| Tables | Use `@tanstack/react-table` only for dense operational tables requiring sorting, filtering, column visibility, row selection, pagination, or bulk operations. Simple lists stay simple. |
| Command/search | Use `cmdk` only if it powers real staff actions such as finding people, active visits, bookings, add-charge targets, checkout, or route jumps. |
| Motion | Use `motion` only for purposeful continuity and feedback: drawer transitions, route/surface changes, state changes, success/error confirmation. No bounce, parallax, or decorative choreography. |
| Charts | Use `recharts` only for reports that answer explicit operational questions about occupancy, revenue, receivables, or trends. Avoid vanity metrics. |
| Drag/drop | Use `@dnd-kit/*` only for real reorder or assignment workflows such as cleaning priority or task assignment. |
| Empty/success states | `dotLottie` is optional only where it improves comprehension; it is not the default completion pattern. |

Any PR that adds a persistent UI dependency must explain the workflow need in the PR body. If the dependency changes the product architecture or broad design direction, record an AgDR.

---

## API Design

The API remains tRPC mounted at `/trpc/*`. Procedures are protected unless explicitly marked public. `healthCheck` can remain public.

### Router Plan

| Router | Representative Procedures | Auth |
|--------|----------------------------|------|
| `branchRouter` | `list`, `setActive`, `getOperationalSummary` | Staff |
| `spaceRouter` | `listMap`, `getAvailability`, `changeStatus`, `history` | Staff + permissions |
| `bookingRouter` | `listCalendar`, `create`, `updateStatus`, `checkIn` | Staff |
| `visitRouter` | `create`, `listActive`, `getDetails`, `close`, `markNonBillable` | Staff |
| `sessionRouter` | `start`, `extend`, `end`, `calculateUsage` | Staff |
| `chargeRouter` | `add`, `updateDraft`, `voidDraft`, `listByTarget` | Cashier/supervisor |
| `checkoutRouter` | `preview`, `finalize`, `splitByResponsibility` | Cashier |
| `invoiceRouter` | `listOpen`, `get`, `finalize`, `recordAdjustment` | Cashier/manager |
| `paymentRouter` | `record`, `list`, `refundOrReverse` | Cashier/manager |
| `shiftRouter` | `open`, `close`, `current`, `cashSummary` | Cashier/supervisor |
| `peopleRouter` | `search`, `quickCreate`, `profile`, `mergeCandidate` | Staff |
| `membershipRouter` | `list`, `create`, `changeStatus`, `coveragePreview` | Staff/manager |
| `tenantRouter` | `list`, `profile`, `guestPolicy`, `hostReceivables` | Staff/manager |
| `eventRouter` | `list`, `create`, `guestList`, `checkInAttendee`, `settlement` | Staff |
| `catalogRouter` | `list`, `create`, `update`, `archive` | Cashier/manager |
| `inventoryRouter` | `stockOnHand`, `movementLedger`, `adjust` | Manager |
| `cleaningRouter` | `queue`, `assign`, `complete` | Cleaner/supervisor |
| `maintenanceRouter` | `list`, `create`, `resolve`, `blockSpace` | Maintenance/supervisor |
| `staffRouter` | `list`, `assignRole`, `branchAccess` | Admin/owner |
| `reportRouter` | `daily`, `occupancy`, `revenue`, `receivables` | Manager/admin |
| `settingsRouter` | `get`, `updatePolicies` | Admin/owner |
| `auditRouter` | `list`, `getEntityTimeline` | Manager/admin |

### Error Responses

Use tRPC error codes consistently:

| Code | When |
|------|------|
| `UNAUTHORIZED` | No Better Auth session. |
| `FORBIDDEN` | Staff profile missing, branch denied, or permission missing. |
| `BAD_REQUEST` | Zod input validation or invalid state transition. |
| `CONFLICT` | Double booking, occupied space, stale invoice/session state. |
| `NOT_FOUND` | Referenced entity missing or outside branch scope. |
| `PRECONDITION_FAILED` | Cash payment without open shift, checkout with unresolved approval. |
| `INTERNAL_SERVER_ERROR` | Unexpected system failure. |

---

## Data Model

### Schema Modules

| Module | Tables |
|--------|--------|
| `workspace.ts` | branches, floors, spaces, space_status_history |
| `people.ts` | people, customer_accounts, tenants, tenant_contacts, hosted_guest_policies |
| `memberships.ts` | membership_plans, membership_plan_benefits, memberships |
| `bookings.ts` | bookings, booking_spaces, booking_deposits |
| `visits.ts` | visits, usage_sessions, hosted_guest_visits |
| `events.ts` | events, event_attendees, event_included_items |
| `billing.ts` | catalog_items, charges, invoices, invoice_items, payments, refunds_adjustments, shifts |
| `operations.ts` | inventory_movements, cleaning_tasks, maintenance_tickets |
| `staff.ts` | staff_profiles, roles, permissions, role_permissions, staff_branch_access |
| `audit.ts` | approval_requests, audit_logs |

### Key Constraints

- `charges` must reference exactly one target: visit, usage session, event attendee/event, host/tenant/account, or invoice draft.
- Active usage sessions cannot overlap for the same space.
- Bookings cannot overlap for the same space unless a domain rule explicitly permits shared capacity.
- Cash payments must reference an open shift for the staff actor.
- Finalized/paid invoice fields are immutable after finalization except via correction records.
- Every sensitive mutation writes an `audit_logs` record inside the same transaction where practical.
- Space state changes are append-only in status history.

### Access Patterns

| Access Pattern | Query Shape |
|----------------|-------------|
| Today dashboard | Branch-scoped active visits, upcoming bookings, open bills, cleaning, maintenance, memberships expiring. |
| Live visits | Branch-scoped visits by status and checked-in time. |
| Space map | Branch/floor spaces with latest status and active session/booking summary. |
| Checkout | Visit/session with charges, membership coverage, responsibility splits, open shift. |
| Reports | Date range aggregates by branch, space type, responsibility, payment method, and staff actor. |
| Audit timeline | Entity key + chronological audit records. |

---

## Implementation Plan

| Step | Work | Dependencies |
|------|------|--------------|
| 0 | Confirm planning package and file tracker issues | This design package |
| 1 | Domain schema, enums, seeds, money/audit/permission helpers | Existing Better Auth and Drizzle setup |
| 2 | Staff shell and protected route layout | Domain constants and staff profile |
| 3 | Today, Live Visits, Space Map, check-in workflows | Domain foundation and shell |
| 4 | Charges, checkout, invoices, payments, shifts | Visit/session workflows |
| 5 | People, memberships, tenants, events | Billing foundation |
| 6 | Catalog, inventory, cleaning, maintenance | Billing foundation |
| 7 | Reports, admin, audit log, settings | Cross-domain data stable |

The detailed milestone graph is maintained in `projects/backspace/initiatives/workspace-operations-management.md`.

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Data model too broad for one PR | High | High | File small domain tickets; one PR per ticket; preserve milestone dependencies. |
| Billing rules drift into UI logic | Medium | High | Keep checkout, split, approval, and immutability in server services with tests. |
| Standalone POS slips into UX | Medium | High | Enforce charge target requirement in schema/API and route UX through Visit/session/event/host/invoice draft. |
| Permissions implemented only visually | Medium | High | Add tRPC permission middleware and server-side authorization tests. |
| Money rounding bugs | Medium | High | Store integer minor units; isolate money helpers; test split/discount/tax scenarios. |
| Migration blast radius | High | High | Use dedicated migration ticket + migration AgDR before editing migration files. |
| Over-navigation slows reception | Medium | Medium | Use drawers, global search, quick actions, and Today/Space Map entry points. |

---

## Security Considerations

- [ ] Every operational route is staff-authenticated via Better Auth protected route/procedure paths.
- [ ] Server procedures require a staff profile and branch access before domain mutations.
- [ ] Restricted actions require explicit permissions and may require approval.
- [ ] Input validation uses Zod schemas at tRPC boundaries.
- [ ] PII is not written to logs beyond stable identifiers needed for operations/audit.
- [ ] Audit logs record actor, action, entity, branch, reason, and before/after where useful.
- [ ] Payment records store internal method/reference only; no external card data is stored.
- [ ] Admin and settings surfaces are hidden in UI and blocked server-side for non-admin roles.

---

## Testing Strategy

| Type | Coverage | Notes |
|------|----------|-------|
| Unit | Money helpers, permission checks, status transitions, checkout split | Required before billing PRs merge. |
| Integration | Visit creation, session start/end, add charge, checkout finalize, payment record | Run against test DB once harness exists. |
| Router | tRPC authorization and validation errors | Verify `UNAUTHORIZED`, `FORBIDDEN`, `CONFLICT`, `PRECONDITION_FAILED`. |
| UI | Staff shell, drawers, disabled permissions, critical flows | Use existing tooling first; add E2E only when project has a chosen harness. |
| Seed smoke | Required operational scenarios from PRD | Must support manual QA/demo. |

Current repository note: issue #4 established the first schema-focused test file for the domain foundation. Future tickets should extend the test surface around money helpers, permission checks, router procedures, checkout flows, forms, tables, and UI state handling instead of returning to a no-test baseline.

---

## Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| Default currency, timezone, and branch for seed data? | Product/Tech Lead | Open |
| Inventory decrement timing: charge finalization or invoice finalization? | Tech Lead | Recommendation: invoice finalization |
| Discount/override threshold requiring supervisor approval? | Product/Manager | Open |
| Event settlement: normal invoices with `event_id` or dedicated event invoice record? | Tech Lead | Open |
| Is a named `Quick Sale Visit` shortcut allowed for rare true quick sales? | Product | Open |
| Initial reporting date ranges and export requirements? | Product/Manager | Open |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | ApexYard PM / OpenCode | 2026-06-23 | Drafted PRD |
| Tech Lead | ApexYard Tech Lead / OpenCode | 2026-06-23 | Author |
| Solution Architect | Tariq | TBD | Pending design review |
| Security Auditor | Shield | TBD | Pending before auth/user-data build PRs |
| UI/UX | TBD | TBD | Pending journey review |

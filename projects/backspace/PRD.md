# Backspace Internal Coworking Management — PRD v0.2

**Status**: Draft  
**Language**: Arabic-only UI  
**Interface**: RTL  
**Product type**: Internal staff web app  
**MVP scope**: One coworking-space location  
**Future direction**: Reusable / white-label-ready for other spaces under another brand

---

## 1. Product Summary

Backspace is an internal web system for managing a coworking space. It is used by workspace owners, managers, reception, and operations staff.

Backspace is **not** customer-facing in the MVP:

- No visitor portal.
- No customer login.
- No public booking flow.
- No online self-service payments.

Visitors/customers are records managed internally by staff.

---

## 2. Target Users

### Primary Users

- **Owner**: full access, settings, financial visibility, staff management.
- **Manager**: operational management, spaces, customers, subscriptions, billing, reports.
- **Staff**: reception/operations workflows: customers, visits, bookings, invoices, payments.

### Explicit Non-Users

- Visitors.
- Customers.
- Members as direct system users.

---

## 3. Goals

1. Replace manual coworking-space operations with one internal web system.
2. Support hourly daily visits with check-in/check-out and automatic cost calculation.
3. Support subscriptions: weekly, biweekly, monthly.
4. Track bookings, invoices, and manual payments.
5. Give owners/managers a clear dashboard for operations and revenue.
6. Keep the MVP Arabic RTL and easy for staff to use.
7. Avoid hardcoded Backspace branding so the system can be reused later.

---

## 4. Non-Goals

- Customer portal.
- Visitor login.
- Public booking page.
- Online payment gateway.
- Mobile app.
- Multi-location / multi-tenant support.
- WhatsApp automation.
- Advanced accounting / ERP.
- Physical access-control integrations.
- Full i18n in v0.

---

## 5. MVP Modules

1. Staff Authentication
2. Single Location Settings
3. Spaces Management
4. Internal Customer Records
5. Hourly Daily Visits
6. Subscription Plans
7. Customer Subscriptions
8. Internal Bookings
9. Invoices
10. Manual Payments
11. Owner/Manager Dashboard
12. Basic Reports
13. Audit / QA Hardening

---

## 6. User Stories

### US-1: Staff Login

As a staff user, I want to log in securely so that I can access internal operations.

**Acceptance Criteria**

- Staff users log in using internal credentials.
- Disabled users cannot log in.
- All internal pages require an authenticated session.
- No customer login exists.

### US-2: Location Settings

As an owner, I want to configure the workspace name, branding, and invoice details so that the product is not hardcoded to Backspace.

**Acceptance Criteria**

- Owner can edit location name, logo, address, phone, currency, invoice prefix, and tax number.
- Staff/Manager cannot edit location settings in v0.
- Invoice numbers use the configured prefix.

### US-3: Spaces Management

As a manager, I want to manage spaces and hourly rates so staff can create visits and bookings accurately.

**Acceptance Criteria**

- Manager can create/edit/deactivate spaces.
- Each space has name, type, capacity, hourly rate, active status, and notes.
- Inactive spaces are not offered for future visits/bookings by default.

### US-4: Internal Customer Records

As staff, I want to create and update internal customer records so the workspace can track visits, subscriptions, bookings, invoices, and payments.

**Acceptance Criteria**

- Staff can create and edit customer records.
- Customer type supports visitor, subscriber, and company.
- Customers do not receive accounts.
- Owner/Manager can archive customers.

### US-5: Hourly Daily Visits

As staff, I want to check customers in and out so the system calculates duration and cost.

**Acceptance Criteria**

- Staff can create a visit for an active customer and active space.
- The visit stores the space hourly-rate snapshot.
- Check-out calculates duration and total cost.
- Minimum billable time is 1 hour; after that, round up to the nearest 30 minutes.

### US-6: Subscriptions

As a manager, I want to sell weekly, biweekly, and monthly subscriptions so recurring customers can be tracked.

**Acceptance Criteria**

- Plans support weekly = 7 days, biweekly = 14 days, monthly = 30 days.
- Customer subscriptions store price snapshot.
- End date is calculated automatically.
- Expiring subscriptions appear in dashboard/reporting.

### US-7: Internal Bookings

As staff, I want to create bookings internally so the team can reserve rooms/spaces for customers.

**Acceptance Criteria**

- Staff can create bookings for active customers and active spaces.
- Confirmed bookings cannot overlap for the same space.
- Cancelled bookings do not block availability.

### US-8: Invoices and Manual Payments

As staff, I want to create invoices and record manual payments so financial records stay organized.

**Acceptance Criteria**

- Invoices can be created for visits, subscriptions, bookings, or manual charges.
- Manual payment methods: cash, bank transfer, external card, other.
- Full payment marks invoice as paid.
- Cancelled invoices cannot accept payments.

### US-9: Dashboard and Reports

As an owner/manager, I want a dashboard and reports so I can understand daily operations and revenue.

**Acceptance Criteria**

- Owner/Manager see revenue widgets.
- Staff see operational widgets without full financial totals.
- Reports cover visits, payments, subscriptions, and bookings.

---

## 7. Success Metrics

| Metric | Target |
|---|---:|
| Staff can create first customer + visit | Same day |
| Visit check-in/check-out flow | Under 1 minute |
| Booking conflict prevention | 100% for confirmed bookings |
| Subscription end-date calculation | 100% correct for weekly/biweekly/monthly |
| Dashboard usefulness for owner/manager | Daily usage |
| Arabic RTL coverage | 100% of MVP pages |

---

## 8. Launch Acceptance

MVP is launch-ready when:

- Owner can log in and configure location settings.
- Staff can create customers, visits, bookings, invoices, and payments.
- Manager can manage spaces and subscriptions.
- Booking conflicts are blocked.
- Hourly visit calculation is correct.
- Role permissions are enforced server-side.
- Dashboard and reports work.
- All UI is Arabic RTL.
- No visitor/customer-facing product exists.

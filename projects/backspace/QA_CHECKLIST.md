# Backspace — MVP QA & Launch Checklist

## Purpose

This checklist verifies the Backspace MVP before internal launch. It covers staff authentication, role permissions, Arabic RTL, daily operations, billing, reports, and the strict internal-only boundary.

---

## 1. Auth & Session

- [ ] `staff_users` table exists.
- [ ] Passwords are stored only as `passwordHash`.
- [ ] No raw passwords are stored or logged.
- [ ] Active staff can log in.
- [ ] Incorrect credentials fail with a generic Arabic error.
- [ ] `isActive = false` blocks login.
- [ ] Logout clears/invalidates session.
- [ ] `GET /api/auth/me` returns current staff user when authenticated.
- [ ] `GET /api/auth/me` returns 401 without session.
- [ ] Every internal page requires `auth/session`.
- [ ] Role authorization is enforced server-side, not UI-only.

---

## 2. Internal-Only Boundary

- [ ] No customer login exists.
- [ ] No visitor login exists.
- [ ] No public booking page exists.
- [ ] No public payment page exists.
- [ ] No public customer dashboard exists.
- [ ] Customers are records only, managed internally by staff.
- [ ] Unauthenticated users are redirected to `/login` or receive 401.

---

## 3. Location Settings

- [ ] `location_settings` table exists.
- [ ] Owner can read location settings.
- [ ] Owner can update location settings.
- [ ] Manager cannot update location settings in v0.
- [ ] Staff cannot update location settings.
- [ ] Location name appears in app UI.
- [ ] `invoicePrefix` is used in invoice numbering.
- [ ] Backspace branding is not hardcoded into business logic.

---

## 4. Arabic RTL

- [ ] Login page is Arabic RTL.
- [ ] Dashboard is Arabic RTL.
- [ ] Spaces pages are Arabic RTL.
- [ ] Customers pages are Arabic RTL.
- [ ] Visits pages are Arabic RTL.
- [ ] Subscriptions pages are Arabic RTL.
- [ ] Bookings pages are Arabic RTL.
- [ ] Invoices/payments pages are Arabic RTL.
- [ ] Reports pages are Arabic RTL.
- [ ] Forms use Arabic labels.
- [ ] Validation messages are Arabic.
- [ ] Tables align correctly in RTL.
- [ ] Currency/date displays are understandable for Arabic-speaking staff.

---

## 5. Spaces

- [ ] `spaces` table exists.
- [ ] Owner can create/edit/deactivate spaces.
- [ ] Manager can create/edit/deactivate spaces.
- [ ] Staff can view spaces.
- [ ] Staff cannot create/edit/deactivate spaces.
- [ ] Space validation requires name, type, capacity > 0, hourly rate >= 0.
- [ ] Deactivated spaces remain in database with `isActive = false`.
- [ ] Deactivated spaces are hidden from default future visit/booking selection.

---

## 6. Customers

- [ ] `customers` table exists.
- [ ] Staff can create customer records.
- [ ] Staff can edit customer records.
- [ ] Customers have no auth/session/login.
- [ ] Customer type supports visitor / subscriber / company.
- [ ] Owner/Manager can archive customers.
- [ ] Staff cannot archive customers.
- [ ] Archived customers are hidden by default.
- [ ] Customer detail page loads.

---

## 7. Daily Hourly Visits

- [ ] `visits` table exists.
- [ ] Staff can create check-in for active customer and active space.
- [ ] Check-in fails for archived customer.
- [ ] Check-in fails for inactive space.
- [ ] `hourlyRateSnapshot` is stored at check-in.
- [ ] Staff can check out an open visit.
- [ ] Check-out calculates `durationMinutes`.
- [ ] Check-out calculates `totalAmount`.
- [ ] Check-out fails if visit is already closed.
- [ ] Check-out fails if checkout time is before/equal check-in time.
- [ ] Staff cannot edit closed visits.
- [ ] Owner/Manager can edit closed visits.
- [ ] Sensitive visit edits write `audit_logs`.

### Visit Calculation Cases

- [ ] 20 minutes bills as 1 hour.
- [ ] 59 minutes bills as 1 hour.
- [ ] 70 minutes bills as 1.5 hours.
- [ ] 91 minutes bills as 2 hours.
- [ ] Total uses `hourlyRateSnapshot`, not current `spaces.hourlyRate`.

---

## 8. Subscriptions

- [ ] `subscription_plans` table exists.
- [ ] `customer_subscriptions` table exists.
- [ ] Owner/Manager can create subscription plans.
- [ ] Staff cannot create subscription plans.
- [ ] Weekly plan uses 7 days.
- [ ] Biweekly plan uses 14 days.
- [ ] Monthly plan uses 30 days.
- [ ] Owner/Manager can create customer subscription.
- [ ] Creating subscription fails for archived customer.
- [ ] Creating subscription fails for inactive plan.
- [ ] `endDate` is calculated automatically.
- [ ] `priceSnapshot` is stored.
- [ ] Owner/Manager can cancel subscription.
- [ ] Staff cannot cancel subscription.
- [ ] Expiring subscriptions appear in dashboard/reporting.

---

## 9. Bookings

- [ ] `bookings` table exists.
- [ ] Staff can create booking for active customer and active space.
- [ ] Booking fails for archived customer.
- [ ] Booking fails for inactive space.
- [ ] `endsAt` must be after `startsAt`.
- [ ] Overlapping confirmed booking is rejected.
- [ ] Adjacent booking ending at start time is allowed.
- [ ] Adjacent booking starting at end time is allowed.
- [ ] Cancelled booking does not block availability.
- [ ] Editing booking time reruns conflict detection.
- [ ] Availability endpoint returns conflicts.
- [ ] Staff can cancel booking.

---

## 10. Invoices & Payments

- [ ] `invoices` table exists.
- [ ] `payments` table exists.
- [ ] Invoice number is unique.
- [ ] Invoice number uses `location_settings.invoicePrefix`.
- [ ] Staff can create manual invoice.
- [ ] Staff can create invoice for closed visit.
- [ ] Cannot create invoice for open visit.
- [ ] Cannot create duplicate invoice for same source.
- [ ] Owner/Manager can cancel invoice.
- [ ] Staff cannot cancel invoice.
- [ ] Staff can register cash payment.
- [ ] Staff can register bank-transfer payment.
- [ ] Staff can register external-card payment.
- [ ] Payment amount must be greater than zero.
- [ ] Cancelled invoice rejects payment.
- [ ] Full payment marks invoice as paid.
- [ ] Payment stores current staff as `receivedByStaffId`.
- [ ] Customer detail page shows invoices and payments.

---

## 11. Dashboard & Reports

- [ ] Dashboard shows open visits.
- [ ] Dashboard shows today visits.
- [ ] Dashboard shows upcoming bookings.
- [ ] Dashboard shows expiring subscriptions.
- [ ] Owner can see revenue widgets.
- [ ] Manager can see revenue widgets.
- [ ] Staff cannot see full revenue widgets.
- [ ] Unpaid invoices exclude cancelled invoices.
- [ ] Occupancy ignores inactive spaces.
- [ ] Visits report filters by date.
- [ ] Visits report filters by space.
- [ ] Payments report is blocked for Staff.
- [ ] Payments report totals use `payments.amount`.
- [ ] Subscriptions report filters active/expired/cancelled.
- [ ] Bookings report filters by status.

---

## 12. Audit & Data Integrity

- [ ] `audit_logs` table exists.
- [ ] Closed visit edits create audit log entries.
- [ ] Invoice cancellations create audit log entries.
- [ ] Subscription cancellations create audit log entries where implemented.
- [ ] Financial-sensitive changes are traceable.
- [ ] `visits.hourlyRateSnapshot` is preserved after space price changes.
- [ ] `customer_subscriptions.priceSnapshot` is preserved after plan price changes.
- [ ] Cancelled invoices do not affect revenue.
- [ ] Cancelled bookings do not affect availability.

---

## 13. Final Launch Acceptance

Backspace MVP can launch when:

- [ ] Owner can log in.
- [ ] Owner can configure `location_settings`.
- [ ] Manager can create `spaces`.
- [ ] Staff can create `customers`.
- [ ] Staff can create and close `visits`.
- [ ] Visit cost calculation is correct.
- [ ] Manager can create `subscription_plans`.
- [ ] Manager can create `customer_subscriptions`.
- [ ] Staff can create `bookings`.
- [ ] Booking conflicts are blocked.
- [ ] Staff can create `invoices`.
- [ ] Staff can register `payments`.
- [ ] Dashboard works for Owner/Manager.
- [ ] Staff dashboard hides full financial data.
- [ ] Reports work.
- [ ] All pages are Arabic RTL.
- [ ] All internal pages require session.
- [ ] No visitor-facing product exists.

---

## 14. Out of MVP Follow-up

Track separately as follow-up items:

- Visitor/customer portal.
- Public booking page.
- Online payment gateway.
- Mobile app.
- Multi-location/multi-tenant.
- WhatsApp automation.
- CSV/Excel export if not included in v0.
- PDF invoice generation if not included in v0.
- Advanced accounting.
- Physical access-control integrations.

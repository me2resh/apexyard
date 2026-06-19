# Backspace — Roadmap

## Roadmap Status

**Current phase**: Planning complete; implementation repo pending  
**MVP target**: Internal Arabic RTL coworking-space management web app  
**Primary users**: Owner, Manager, Staff  
**Explicitly excluded from MVP**: Visitor/customer portal

---

## MVP Release Theme

The MVP should let a coworking-space team run daily operations from one internal system:

- Staff login and protected internal workspace.
- Configurable single-location branding and invoice settings.
- Spaces and customer records.
- Hourly visits with check-in/check-out.
- Weekly, biweekly, and monthly subscriptions.
- Internal bookings with conflict prevention.
- Invoices and manual payments.
- Owner/manager dashboard and reports.

---

## Milestone 0 — Implementation Foundation

**Goal**: Create the implementation repository and basic app foundation.

### Includes

- Create project repo/workspace.
- Create Next.js TypeScript app.
- Configure PostgreSQL database and migrations.
- Configure test/lint/typecheck commands.
- Build Arabic RTL app shell.

### Exit Criteria

- App runs locally.
- Database connection works.
- Initial migration runs.
- Arabic RTL layout foundation exists.
- README has local setup instructions.

### Backlog Items

- `BSP-FOUND-001`
- `BSP-FOUND-002`
- `BSP-FOUND-003`

---

## Milestone 1 — Secure Internal Access

**Goal**: Let the owner log in and configure the workspace.

### Includes

- `staff_users` model.
- Owner seed account.
- Login/logout/current-user session.
- Protected internal routes.
- `location_settings` configuration.

### Exit Criteria

- Active owner can log in.
- Disabled staff cannot log in.
- All protected pages require session.
- Owner can edit location settings.
- Branding and invoice prefix come from `location_settings`.

### Backlog Items

- `BSP-AUTH-001`
- `BSP-AUTH-002`
- `BSP-AUTH-003`

---

## Milestone 2 — Operations Records

**Goal**: Create the core operational records needed before visits/bookings/subscriptions.

### Includes

- Spaces management.
- Internal customer records.
- Customer detail shell.

### Exit Criteria

- Owner/Manager can manage spaces.
- Staff can view spaces.
- Staff can create/edit customers.
- Customers have no login.
- Customer detail page is ready to receive visits/subscriptions/bookings/billing history.

### Backlog Items

- `BSP-OPS-001`
- `BSP-OPS-002`

---

## Milestone 3 — Daily Visits

**Goal**: Support walk-in/day-use hourly operations.

### Includes

- Visit check-in.
- Visit check-out.
- Duration and cost calculation.
- Visit corrections and audit logs.

### Exit Criteria

- Staff can start and close visits.
- Visit pricing uses `hourlyRateSnapshot`.
- Minimum billable time is 1 hour, then rounds up to nearest 30 minutes.
- Staff cannot edit closed visits.
- Owner/Manager corrections are audited.

### Backlog Items

- `BSP-VISIT-001`
- `BSP-VISIT-002`
- `BSP-VISIT-003`

---

## Milestone 4 — Subscriptions

**Goal**: Support recurring customers with fixed-duration subscriptions.

### Includes

- Subscription plans.
- Customer subscriptions.
- Expiry tracking.

### Exit Criteria

- Weekly = 7 days.
- Biweekly = 14 days.
- Monthly = 30 days.
- `priceSnapshot` is preserved.
- Staff can view but not create/cancel subscriptions.

### Backlog Items

- `BSP-SUB-001`
- `BSP-SUB-002`

---

## Milestone 5 — Internal Bookings

**Goal**: Support staff-created reservations without double-booking spaces.

### Includes

- Booking CRUD.
- Availability checks.
- Conflict prevention.

### Exit Criteria

- Staff can create/cancel bookings.
- Overlapping confirmed bookings for the same space are blocked.
- Adjacent bookings are allowed.
- Cancelled bookings do not block availability.

### Backlog Items

- `BSP-BOOK-001`
- `BSP-BOOK-002`

---

## Milestone 6 — Billing

**Goal**: Track invoices and manual payments.

### Includes

- Invoices.
- Manual payments.
- Customer financial history.

### Exit Criteria

- Invoice numbers use `location_settings.invoicePrefix`.
- Invoices work for visits, subscriptions, bookings/manual charges.
- Payments support cash, bank transfer, external card, and other.
- Full payment marks invoice paid.
- Cancelled invoices reject new payments.

### Backlog Items

- `BSP-BILL-001`
- `BSP-BILL-002`

---

## Milestone 7 — Visibility

**Goal**: Give owner/manager the operational and financial overview needed to run the space.

### Includes

- Role-aware dashboard.
- Basic reports.

### Exit Criteria

- Dashboard shows open visits, today visits, upcoming bookings, and expiring subscriptions.
- Owner/Manager see revenue widgets.
- Staff do not see full financial widgets.
- Reports cover visits, payments, subscriptions, and bookings.

### Backlog Items

- `BSP-DASH-001`
- `BSP-DASH-002`

---

## Milestone 8 — MVP Launch Hardening

**Goal**: Verify the product is safe and usable for internal launch.

### Includes

- Full QA checklist.
- Security and data integrity review.
- Arabic RTL review.
- Internal-only boundary verification.

### Exit Criteria

- All P0 QA checks pass.
- All internal pages require session.
- Role permissions are enforced server-side.
- No customer/visitor-facing product exists.
- Financial-sensitive changes are traceable.

### Backlog Items

- `BSP-QA-001`
- `BSP-QA-002`

---

## Post-MVP Roadmap

### P1 Enhancements

- PDF invoice export.
- CSV/Excel reports export.
- Partial payments with remaining balance tracking.
- More detailed staff permissions.
- Customer duplicate detection by phone.
- WhatsApp/SMS reminders for expiring subscriptions.
- Better calendar view for bookings.

### P2 Enhancements

- Online payment gateway.
- Customer/visitor portal.
- Public booking page.
- Multi-location support.
- White-label admin for multiple brands.
- Mobile app.
- Advanced accounting reports.
- Access-control hardware integration.

---

## Go / No-Go Summary

### Go when

- Staff can run daily visits end-to-end.
- Subscriptions work end-to-end.
- Bookings cannot conflict.
- Invoices and manual payments are reliable.
- Owner/Manager dashboard is useful.
- Staff financial restrictions work.
- Arabic RTL is complete.
- No visitor portal exists.

### No-Go if

- Any internal page is accessible without session.
- Role permissions are only enforced in UI.
- Visit or invoice calculations are unreliable.
- Booking conflicts can occur.
- Raw passwords are stored.
- Staff can access owner-only settings or restricted financial widgets.

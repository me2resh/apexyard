# Backspace — Technical Design v0.1

## 1. Overview

Backspace is an internal Arabic RTL web application for managing one coworking-space location. The MVP should be implemented as a **modular monolith** to keep delivery fast and simple while preserving clear module boundaries.

The product must remain reusable/white-label-ready by storing workspace branding and invoice data in `location_settings` instead of hardcoding Backspace-specific details.

---

## 2. Architecture

### Recommended Shape

- Modular monolith web app.
- Server-side role authorization for all protected APIs.
- Auth/session required for every internal page.
- Database-backed domain entities.
- Arabic RTL UI.

### Core Modules

1. Auth & Staff Roles
2. Location Settings
3. Spaces
4. Customers
5. Visits
6. Subscriptions
7. Bookings
8. Billing
9. Dashboard & Reports
10. Audit Logs

---

## 3. Domain Model

### `staff_users`

Internal staff accounts only.

| Field | Notes |
|---|---|
| `id` | primary key |
| `name` | staff display name |
| `email` | unique login identifier |
| `passwordHash` | hashed password only; never raw password |
| `role` | owner / manager / staff |
| `isActive` | disabled users cannot log in |
| `createdAt`, `updatedAt` | timestamps |

### `location_settings`

Single-location configuration.

| Field | Notes |
|---|---|
| `id` | single row |
| `locationName` | configurable workspace name |
| `logoUrl` | optional |
| `address` | optional |
| `phone` | optional |
| `invoicePrefix` | used for invoice numbers |
| `taxNumber` | optional |
| `currency` | default EGP |
| `updatedAt` | timestamp |

### `spaces`

| Field | Notes |
|---|---|
| `id` | primary key |
| `name` | space name |
| `type` | meeting room / office / shared area / etc. |
| `capacity` | integer > 0 |
| `hourlyRate` | decimal >= 0 |
| `isActive` | inactive spaces hidden from default future selection |
| `notes` | optional |
| `createdAt`, `updatedAt` | timestamps |

### `customers`

Internal customer records only; no login.

| Field | Notes |
|---|---|
| `id` | primary key |
| `name` | required |
| `phone` | required |
| `email` | optional |
| `type` | visitor / subscriber / company |
| `notes` | optional |
| `archivedAt` | archive instead of hard delete |
| `createdAt`, `updatedAt` | timestamps |

### `visits`

Hourly daily visits.

| Field | Notes |
|---|---|
| `id` | primary key |
| `customerId` | FK customers |
| `spaceId` | FK spaces |
| `checkInAt` | required |
| `checkOutAt` | nullable |
| `durationMinutes` | calculated on checkout |
| `hourlyRateSnapshot` | copied from space at check-in |
| `totalAmount` | calculated on checkout |
| `status` | open / closed / cancelled |
| `notes` | optional |
| `createdByStaffId` | FK staff_users |
| `closedByStaffId` | nullable FK staff_users |
| `createdAt`, `updatedAt` | timestamps |

### `subscription_plans`

| Field | Notes |
|---|---|
| `id` | primary key |
| `name` | required |
| `durationType` | weekly / biweekly / monthly |
| `durationDays` | 7 / 14 / 30 |
| `price` | decimal >= 0 |
| `isActive` | active plans can be sold |
| `createdAt`, `updatedAt` | timestamps |

### `customer_subscriptions`

| Field | Notes |
|---|---|
| `id` | primary key |
| `customerId` | FK customers |
| `planId` | FK subscription_plans |
| `startDate` | required |
| `endDate` | calculated |
| `priceSnapshot` | copied from plan at sale time |
| `status` | active / expired / cancelled |
| `notes` | optional |
| `createdAt`, `updatedAt` | timestamps |

### `bookings`

| Field | Notes |
|---|---|
| `id` | primary key |
| `customerId` | FK customers |
| `spaceId` | FK spaces |
| `startsAt` | required |
| `endsAt` | required, after startsAt |
| `status` | confirmed / cancelled / completed |
| `notes` | optional |
| `createdByStaffId` | FK staff_users |
| `createdAt`, `updatedAt` | timestamps |

### `invoices`

| Field | Notes |
|---|---|
| `id` | primary key |
| `invoiceNumber` | unique; uses `location_settings.invoicePrefix` |
| `customerId` | FK customers |
| `sourceType` | visit / subscription / booking / manual |
| `sourceId` | nullable for manual invoices |
| `subtotal` | decimal |
| `total` | decimal |
| `status` | unpaid / paid / overdue / cancelled |
| `issuedAt` | timestamp |
| `dueAt` | nullable |
| `createdAt`, `updatedAt` | timestamps |

### `payments`

| Field | Notes |
|---|---|
| `id` | primary key |
| `invoiceId` | FK invoices |
| `amount` | decimal > 0 |
| `method` | cash / bank_transfer / external_card / other |
| `paidAt` | timestamp |
| `receivedByStaffId` | FK staff_users |
| `notes` | optional |
| `createdAt` | timestamp |

### `audit_logs`

For sensitive changes.

| Field | Notes |
|---|---|
| `id` | primary key |
| `actorStaffId` | FK staff_users |
| `action` | string |
| `entityType` | string |
| `entityId` | uuid |
| `before` | optional JSON |
| `after` | optional JSON |
| `createdAt` | timestamp |

---

## 4. Permissions Matrix

| Capability | Owner | Manager | Staff |
|---|---:|---:|---:|
| Login | ✅ | ✅ | ✅ |
| Update `location_settings` | ✅ | ❌ | ❌ |
| Manage `staff_users` | ✅ | ❌ | ❌ |
| Manage `spaces` | ✅ | ✅ | ❌ |
| Create/Edit `customers` | ✅ | ✅ | ✅ |
| Archive `customers` | ✅ | ✅ | ❌ |
| Create/close `visits` | ✅ | ✅ | ✅ |
| Edit closed `visits` | ✅ | ✅ | ❌ |
| Manage `subscription_plans` | ✅ | ✅ | ❌ |
| Create/cancel `customer_subscriptions` | ✅ | ✅ | ❌ |
| Create/cancel `bookings` | ✅ | ✅ | ✅ |
| Create `invoices` | ✅ | ✅ | ✅ |
| Cancel `invoices` | ✅ | ✅ | ❌ |
| Register `payments` | ✅ | ✅ | ✅ |
| Full financial dashboard | ✅ | ✅ | ❌ |

---

## 5. API Map

### Auth

- `POST /api/auth/login`
- `POST /api/auth/logout`
- `GET /api/auth/me`

### Staff Users

- `GET /api/staff` — Owner
- `POST /api/staff` — Owner
- `PATCH /api/staff/:id` — Owner
- `PATCH /api/staff/:id/deactivate` — Owner

### Location Settings

- `GET /api/settings/location`
- `PATCH /api/settings/location` — Owner

### Spaces

- `GET /api/spaces`
- `POST /api/spaces` — Owner/Manager
- `PATCH /api/spaces/:id` — Owner/Manager
- `PATCH /api/spaces/:id/deactivate` — Owner/Manager

### Customers

- `GET /api/customers`
- `POST /api/customers`
- `GET /api/customers/:id`
- `PATCH /api/customers/:id`
- `PATCH /api/customers/:id/archive` — Owner/Manager

### Visits

- `GET /api/visits`
- `POST /api/visits/check-in`
- `POST /api/visits/:id/check-out`
- `PATCH /api/visits/:id` — Owner/Manager
- `PATCH /api/visits/:id/cancel` — Owner/Manager

### Subscriptions

- `GET /api/subscription-plans`
- `POST /api/subscription-plans` — Owner/Manager
- `PATCH /api/subscription-plans/:id` — Owner/Manager
- `GET /api/subscriptions`
- `POST /api/subscriptions` — Owner/Manager
- `PATCH /api/subscriptions/:id/cancel` — Owner/Manager

### Bookings

- `GET /api/bookings`
- `GET /api/bookings/availability`
- `POST /api/bookings`
- `PATCH /api/bookings/:id`
- `PATCH /api/bookings/:id/cancel`

### Billing

- `GET /api/invoices`
- `POST /api/invoices`
- `GET /api/invoices/:id`
- `PATCH /api/invoices/:id/cancel` — Owner/Manager
- `POST /api/payments`
- `GET /api/invoices/:id/payments`

### Dashboard / Reports

- `GET /api/dashboard/today`
- `GET /api/dashboard/revenue` — Owner/Manager
- `GET /api/dashboard/expiring-subscriptions`
- `GET /api/dashboard/unpaid-invoices` — Owner/Manager
- `GET /api/dashboard/occupancy`
- `GET /api/reports/visits`
- `GET /api/reports/payments` — Owner/Manager
- `GET /api/reports/subscriptions`
- `GET /api/reports/bookings`

---

## 6. Business Rules

### Auth

- Only active `staff_users` may log in.
- Use `passwordHash`; never store raw passwords.
- Every internal page requires `auth/session`.
- Role authorization must be server-side.

### Visits

- Check-in requires active customer and active space.
- Save `hourlyRateSnapshot` at check-in.
- Checkout computes `durationMinutes` and `totalAmount`.
- Minimum billable time is one hour, then round up to nearest 30 minutes.

### Subscriptions

- weekly = 7 days.
- biweekly = 14 days.
- monthly = 30 days.
- Save `priceSnapshot` on customer subscription.

### Bookings

No two confirmed bookings may overlap for the same space:

```text
new.startsAt < existing.endsAt
AND new.endsAt > existing.startsAt
AND existing.status = confirmed
AND existing.spaceId = new.spaceId
```

### Billing

- Invoice numbers use `location_settings.invoicePrefix`.
- Full payment marks invoice `paid`.
- Cancelled invoices reject new payments.
- Financial cancellations should write `audit_logs`.

---

## 7. Screen Map

- `/login`
- `/dashboard`
- `/spaces`
- `/customers`
- `/customers/:id`
- `/visits`
- `/subscriptions`
- `/bookings`
- `/invoices`
- `/reports`
- `/settings/location`
- `/settings/staff`

All screens are Arabic RTL and internal-only.

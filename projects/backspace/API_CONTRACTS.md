# Backspace — API Contracts Draft

## Purpose

This document defines draft API contracts for the Backspace MVP implementation. It complements:

- `projects/backspace/README.md`
- `projects/backspace/TECHNICAL_DESIGN.md`
- `projects/backspace/PRISMA_SCHEMA_DRAFT.md`

Core entities covered here include `StaffUser`, `LocationSettings`, `Space`, `Customer`, `Visit`, `SubscriptionPlan`, `CustomerSubscription`, and `Booking`, plus billing/dashboard/reporting resources.

---

## Global Rules

- All API routes are internal staff-only unless explicitly stated otherwise.
- There are no visitor/customer-facing APIs in the MVP.
- Unauthenticated requests return `401`.
- Authenticated users without permission return `403`.
- Validation errors return `400` with Arabic-safe messages.
- Not found resources return `404`.
- Mutations should be server-side authorized, not UI-only.

---

## Error Shape

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "البيانات غير صحيحة",
    "fields": {
      "name": "الاسم مطلوب"
    }
  }
}
```

Common codes:

- `UNAUTHORIZED`
- `FORBIDDEN`
- `NOT_FOUND`
- `VALIDATION_ERROR`
- `CONFLICT`
- `INTERNAL_ERROR`

---

## Auth

### `POST /api/auth/login`

Authenticates a `StaffUser`.

**Body**

```json
{
  "email": "owner@example.local",
  "password": "<submitted-password>"
}
```

**Success**

```json
{
  "user": {
    "id": "uuid",
    "name": "مالك النظام",
    "email": "owner@example.local",
    "role": "owner"
  }
}
```

**Rules**

- Compare submitted password against `StaffUser.passwordHash`.
- Reject if `StaffUser.isActive = false`.
- Use generic login error messages.

### `POST /api/auth/logout`

```json
{ "ok": true }
```

### `GET /api/auth/me`

Returns current staff user.

---

## Location Settings

### `GET /api/settings/location`

Allowed: Owner, Manager, Staff.

**Response**

```json
{
  "location": {
    "id": "uuid",
    "locationName": "Backspace",
    "logoUrl": null,
    "address": null,
    "phone": null,
    "invoicePrefix": "BS",
    "taxNumber": null,
    "currency": "EGP"
  }
}
```

### `PATCH /api/settings/location`

Allowed: Owner only.

**Body**

```json
{
  "locationName": "Backspace",
  "logoUrl": null,
  "address": "العنوان",
  "phone": "01000000000",
  "invoicePrefix": "BS",
  "taxNumber": null,
  "currency": "EGP"
}
```

---

## Spaces

### `GET /api/spaces`

Allowed: Owner, Manager, Staff.

**Query**

- `isActive=true|false`
- `search=...`

### `POST /api/spaces`

Allowed: Owner, Manager.

**Body**

```json
{
  "name": "غرفة اجتماعات 1",
  "type": "meeting_room",
  "capacity": 6,
  "hourlyRate": 150,
  "notes": "بها شاشة"
}
```

**Validation**

- `name` required.
- `capacity > 0`.
- `hourlyRate >= 0`.

### `PATCH /api/spaces/:id`

Allowed: Owner, Manager.

### `PATCH /api/spaces/:id/deactivate`

Allowed: Owner, Manager.

---

## Customers

### `GET /api/customers`

Allowed: Owner, Manager, Staff.

**Query**

- `search=...`
- `type=visitor|subscriber|company`
- `archived=true|false`

### `POST /api/customers`

Allowed: Owner, Manager, Staff.

**Body**

```json
{
  "name": "أحمد محمد",
  "phone": "01000000000",
  "email": null,
  "type": "visitor",
  "notes": "عميل يومي"
}
```

### `GET /api/customers/:id`

Returns customer details plus related history sections when implemented.

### `PATCH /api/customers/:id`

Allowed: Owner, Manager, Staff.

### `PATCH /api/customers/:id/archive`

Allowed: Owner, Manager.

---

## Visits

### `GET /api/visits`

Allowed: Owner, Manager, Staff.

**Query**

- `status=open|closed|cancelled`
- `date=YYYY-MM-DD`
- `customerId=uuid`
- `spaceId=uuid`

### `POST /api/visits/check-in`

Allowed: Owner, Manager, Staff.

**Body**

```json
{
  "customerId": "uuid",
  "spaceId": "uuid",
  "checkInAt": "2026-06-16T10:00:00.000Z",
  "notes": "زيارة يومية"
}
```

**Rules**

- Customer must not be archived.
- Space must be active.
- Store `hourlyRateSnapshot` from selected `Space`.
- New `Visit.status = open`.

### `POST /api/visits/:id/check-out`

Allowed: Owner, Manager, Staff.

**Body**

```json
{
  "checkOutAt": "2026-06-16T12:20:00.000Z",
  "notes": "تم إنهاء الزيارة"
}
```

**Response**

```json
{
  "visit": {
    "id": "uuid",
    "status": "closed",
    "durationMinutes": 140,
    "totalAmount": 375
  }
}
```

**Rules**

- Visit must be open.
- Checkout must be after check-in.
- Minimum billable duration: 1 hour.
- After first hour, round up to nearest 30 minutes.

### `PATCH /api/visits/:id`

Allowed: Owner, Manager.

### `PATCH /api/visits/:id/cancel`

Allowed: Owner, Manager.

---

## Subscription Plans

### `GET /api/subscription-plans`

Allowed: Owner, Manager, Staff.

### `POST /api/subscription-plans`

Allowed: Owner, Manager.

**Body**

```json
{
  "name": "اشتراك أسبوعي",
  "durationType": "weekly",
  "price": 500
}
```

**Rules**

- `weekly` => `durationDays = 7`.
- `biweekly` => `durationDays = 14`.
- `monthly` => `durationDays = 30`.

### `PATCH /api/subscription-plans/:id`

Allowed: Owner, Manager.

---

## Customer Subscriptions

### `GET /api/subscriptions`

Allowed: Owner, Manager, Staff.

**Query**

- `status=active|expired|cancelled`
- `customerId=uuid`
- `expiringWithinDays=7`

### `POST /api/subscriptions`

Allowed: Owner, Manager.

**Body**

```json
{
  "customerId": "uuid",
  "planId": "uuid",
  "startDate": "2026-06-16",
  "notes": "اشتراك جديد"
}
```

**Rules**

- Customer must not be archived.
- Plan must be active.
- Store `priceSnapshot`.
- Calculate `endDate` from `SubscriptionPlan.durationDays`.

### `PATCH /api/subscriptions/:id/cancel`

Allowed: Owner, Manager.

---

## Bookings

### `GET /api/bookings`

Allowed: Owner, Manager, Staff.

**Query**

- `date=YYYY-MM-DD`
- `spaceId=uuid`
- `customerId=uuid`
- `status=confirmed|cancelled|completed`

### `GET /api/bookings/availability`

Allowed: Owner, Manager, Staff.

**Query**

- `spaceId=uuid`
- `startsAt=ISO datetime`
- `endsAt=ISO datetime`

**Response**

```json
{
  "available": false,
  "conflicts": [
    {
      "bookingId": "uuid",
      "startsAt": "2026-06-16T10:00:00.000Z",
      "endsAt": "2026-06-16T12:00:00.000Z"
    }
  ]
}
```

### `POST /api/bookings`

Allowed: Owner, Manager, Staff.

**Body**

```json
{
  "customerId": "uuid",
  "spaceId": "uuid",
  "startsAt": "2026-06-16T10:00:00.000Z",
  "endsAt": "2026-06-16T12:00:00.000Z",
  "notes": "حجز غرفة اجتماع"
}
```

**Rules**

- Customer must not be archived.
- Space must be active.
- `endsAt > startsAt`.
- No overlapping confirmed booking for the same `Space`.

### `PATCH /api/bookings/:id`

Allowed: Owner, Manager, Staff.

### `PATCH /api/bookings/:id/cancel`

Allowed: Owner, Manager, Staff.

---

## Invoices

### `GET /api/invoices`

Allowed: Owner, Manager, Staff.

**Query**

- `status=unpaid|paid|overdue|cancelled`
- `customerId=uuid`
- `sourceType=visit|subscription|booking|manual`
- `from=YYYY-MM-DD`
- `to=YYYY-MM-DD`

### `POST /api/invoices`

Allowed: Owner, Manager, Staff.

**Visit Invoice Body**

```json
{
  "customerId": "uuid",
  "sourceType": "visit",
  "sourceId": "uuid",
  "dueAt": null
}
```

**Manual Invoice Body**

```json
{
  "customerId": "uuid",
  "sourceType": "manual",
  "items": [
    {
      "description": "طباعة مستندات",
      "amount": 50
    }
  ],
  "dueAt": "2026-06-20T00:00:00.000Z"
}
```

**Rules**

- Invoice numbers use `LocationSettings.invoicePrefix`.
- Closed visits can be invoiced.
- Open visits cannot be invoiced.
- Duplicate invoice for same non-manual source is blocked.

### `GET /api/invoices/:id`

Returns invoice, customer, source summary, and payments.

### `PATCH /api/invoices/:id/cancel`

Allowed: Owner, Manager.

---

## Payments

### `POST /api/payments`

Allowed: Owner, Manager, Staff.

**Body**

```json
{
  "invoiceId": "uuid",
  "amount": 300,
  "method": "cash",
  "paidAt": "2026-06-16T12:00:00.000Z",
  "notes": "تم الدفع نقدًا"
}
```

**Rules**

- `amount > 0`.
- Cancelled invoices reject payments.
- Full payment marks invoice as paid.
- `receivedByStaffId` comes from authenticated `StaffUser`.

### `GET /api/invoices/:id/payments`

Allowed: Owner, Manager, Staff.

---

## Dashboard

### `GET /api/dashboard/today`

Allowed: Owner, Manager, Staff.

Returns open visits count, closed visits count, today bookings, upcoming bookings, expiring subscription count.

### `GET /api/dashboard/revenue`

Allowed: Owner, Manager.

Returns paid totals based on `payments.amount`, plus unpaid/overdue invoice totals.

### `GET /api/dashboard/expiring-subscriptions`

Allowed: Owner, Manager, Staff.

### `GET /api/dashboard/unpaid-invoices`

Allowed: Owner, Manager.

### `GET /api/dashboard/occupancy`

Allowed: Owner, Manager, Staff.

---

## Reports

### `GET /api/reports/visits`

Allowed: Owner, Manager, Staff.

### `GET /api/reports/payments`

Allowed: Owner, Manager.

### `GET /api/reports/subscriptions`

Allowed: Owner, Manager, Staff.

### `GET /api/reports/bookings`

Allowed: Owner, Manager, Staff.

---

## Implementation Notes

- Prefer shared Zod schemas for request validation.
- Keep Arabic validation messages close to form/API boundaries.
- Keep business calculations in tested domain functions.
- Keep role checks reusable and server-side.
- Add tests for `Visit` cost calculation, `Booking` conflict detection, `CustomerSubscription` end-date calculation, and invoice/payment state changes.

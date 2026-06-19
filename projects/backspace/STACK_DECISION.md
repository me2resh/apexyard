# Backspace — Stack Decision

## Decision

Backspace MVP will be implemented using:

- **Frontend/App Framework**: Next.js
- **Database**: PostgreSQL
- **Product Shape**: Internal Arabic RTL web app
- **Architecture Shape**: Modular monolith

---

## Why This Stack

### Next.js

Next.js is a strong fit for Backspace because the product is a web-first internal operations system with:

- Authenticated staff-only pages.
- Dashboard and reporting screens.
- Form-heavy CRUD workflows.
- Arabic RTL UI requirements.
- API endpoints colocated with the app where appropriate.
- Fast MVP delivery.

### PostgreSQL

PostgreSQL is a strong fit because Backspace has relational operational data:

- Staff users and roles.
- Spaces.
- Customers.
- Visits.
- Subscriptions.
- Bookings.
- Invoices.
- Payments.
- Audit logs.

The domain needs constraints, filtering, reporting, date ranges, financial records, and reliable relational integrity.

---

## Recommended Supporting Choices

These are recommended defaults for Sprint 0 unless implementation constraints require otherwise. The concrete defaults are finalized in [Implementation Defaults](./IMPLEMENTATION_DEFAULTS.md).

| Area | Recommendation | Reason |
|---|---|---|
| Language | TypeScript | Safer domain/API contracts |
| Styling | Tailwind CSS | Fast Arabic RTL UI implementation |
| UI primitives | shadcn/ui or equivalent | Speeds admin UI forms/tables/dialogs |
| ORM | Prisma or Drizzle | Typed database access and migrations |
| Auth | Session-based staff auth | Internal-only app, no customer login |
| Validation | Zod | Shared request/form validation |
| Testing | Unit + integration tests | Required for pricing, permissions, conflicts |
| Deployment | TBD | Decide after repo/environment choice |

---

## Architecture Implications

The app should remain a modular monolith with clear module folders, for example:

```text
src/
  app/
  modules/
    auth/
    location-settings/
    spaces/
    customers/
    visits/
    subscriptions/
    bookings/
    billing/
    dashboard/
    reports/
    audit/
  db/
  ui/
```

Each module should own:

- Data access/query functions.
- Validation schemas.
- Server actions or API route handlers.
- Permission checks.
- Tests for business rules.

---

## Database Direction

PostgreSQL should enforce core integrity where practical:

- Unique staff email.
- Unique invoice number.
- Foreign keys for customer/space/staff relationships.
- Status enums or constrained text values.
- Indexes for date filters and dashboard/report queries.

Important tables from the approved technical design:

- `staff_users`
- `location_settings`
- `spaces`
- `customers`
- `visits`
- `subscription_plans`
- `customer_subscriptions`
- `bookings`
- `invoices`
- `payments`
- `audit_logs`

---

## Non-Negotiable Product Constraints

The stack decision does not change the product boundary:

- Backspace remains internal-only in MVP.
- No visitor/customer login.
- No public booking page.
- No online payment gateway in v0.
- Arabic RTL must be part of the first app shell.
- `location_settings` must prevent hardcoded Backspace branding.
- `staff_users.passwordHash` must be used; no raw password storage.
- `staff_users.isActive` must block disabled accounts.

---

## Sprint 0 Update

Sprint 0 should now create a Next.js + PostgreSQL foundation:

1. Create Next.js TypeScript app.
2. Configure Arabic RTL layout.
3. Configure PostgreSQL local database.
4. Add migration tooling.
5. Add lint/typecheck/test commands.
6. Add environment variable template.
7. Add first empty health/check page or protected shell placeholder.

---

## Open Implementation Choices

Need final selection before coding:

Resolved in [Implementation Defaults](./IMPLEMENTATION_DEFAULTS.md):

1. ORM default: Prisma.
2. Auth direction: custom session-based staff auth.
3. UI component system default: shadcn/ui with Tailwind CSS.
4. Local database default: Docker Compose PostgreSQL.

Still open:

1. Deployment target: Vercel, VPS, Docker, or other.
2. Package manager preference.
3. Exact session storage mechanism.
4. Whether PDF invoices are included in v0 or P1.
5. Whether CSV/Excel export is included in v0 or P1.

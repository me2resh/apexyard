# Backspace — Implementation Defaults

## Purpose

This document turns the selected stack decision into concrete Sprint 0 defaults so engineering can start without re-opening every tooling question.

Backspace stack is already selected as:

- Next.js
- PostgreSQL
- TypeScript
- Modular monolith
- Arabic RTL internal admin app

---

## Recommended Defaults

| Area | Default | Rationale |
|---|---|---|
| App framework | Next.js App Router | Modern Next.js structure for server-rendered internal pages and colocated server logic |
| Language | TypeScript | Safer domain model, API contracts, and form validation |
| Database | PostgreSQL | Strong relational integrity for operational and financial data |
| ORM | Prisma | Fast onboarding, clear migrations, strong TypeScript types |
| Validation | Zod | Shared schemas for forms and API/server actions |
| Styling | Tailwind CSS | Fast RTL-compatible admin UI styling |
| UI components | shadcn/ui | Good fit for forms, tables, dialogs, cards, and dashboards |
| Auth model | Session-based staff auth | Internal-only product; no customer auth needed |
| Password hashing | Argon2 or bcrypt | Never store raw passwords; store `staff_users.passwordHash` only |
| Local database | Docker Compose PostgreSQL | Repeatable local setup for all engineers |
| Tests | Vitest + integration tests | Business-rule coverage for pricing, permissions, booking conflicts |
| E2E smoke | Playwright later in hardening | Useful for auth, RTL flows, and core operations |
| Deployment | Decide later | Depends on hosting preference and budget |

---

## ORM Decision

### Default: Prisma

Use Prisma for the MVP unless implementation constraints require Drizzle.

Reasons:

- Clear schema file for a relational domain.
- Good migration workflow.
- Fast for CRUD-heavy internal admin apps.
- Strong TypeScript client.
- Easy for future contributors to understand.

### Tables to model first

Sprint 1:

- `staff_users`
- `location_settings`

Sprint 2+:

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

## Auth Default

### Default: custom staff session auth

Because Backspace is internal-only and has no customer login, keep auth simple and explicit:

- Staff login only.
- Session cookie.
- Server-side session lookup.
- Server-side role checks.
- `staff_users.isActive` checked at login and preferably on session validation.

Non-negotiable:

- No raw passwords.
- Only `passwordHash`.
- Generic login errors.
- All protected routes require session.
- Staff/customer separation remains absolute: customers never authenticate.

---

## UI Default

### Default: Tailwind CSS + shadcn/ui

Use shadcn/ui as a component starting point for:

- Buttons
- Inputs
- Selects
- Dialogs
- Tables
- Cards
- Tabs
- Toasts/alerts

Arabic RTL requirements:

- Set root/app direction to `rtl`.
- Use Arabic labels from the first screen.
- Avoid layout assumptions that depend on LTR.
- Verify tables, modals, sidebars, and form validation in RTL.

---

## Local Development Default

Use Docker Compose for local PostgreSQL.

Expected local files once implementation starts:

```text
.env.example
compose.yaml
prisma/schema.prisma
src/
```

`.env.example` should include placeholders only, never real secrets.

Example variables:

```text
DATABASE_URL=postgresql://backspace:backspace@localhost:5432/backspace
SESSION_SECRET=change-me-in-development
```

---

## Suggested Initial App Structure

```text
src/
  app/
    (auth)/
      login/
    (app)/
      dashboard/
      spaces/
      customers/
      visits/
      subscriptions/
      bookings/
      invoices/
      reports/
      settings/
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
  lib/
```

Guideline:

- `app/` owns routes/screens.
- `modules/` owns domain logic, validation, permissions, and data access.
- `db/` owns Prisma client and database helpers.
- `ui/` owns shared UI components.
- `lib/` owns cross-cutting utilities.

---

## First Sprint 0 Commands — Draft

Exact commands may change based on package manager, but the intended setup is:

```bash
npx create-next-app@latest backspace --ts --eslint --tailwind --app
cd backspace
npm install prisma @prisma/client zod
npm install -D vitest
npx prisma init
```

If using shadcn/ui:

```bash
npx shadcn@latest init
```

Then add Docker Compose PostgreSQL and update `.env.example`.

---

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| RTL added too late | Make Arabic RTL part of Sprint 0 app shell |
| Role checks implemented only in UI | Add server-side authorization helper before feature modules |
| Financial calculations drift | Put visit/subscription/billing calculations in tested domain functions |
| Booking conflicts missed under concurrency | Enforce conflict check in transaction where possible |
| Branding hardcoded | Read app name/invoice prefix from `location_settings` |
| Customer portal accidentally added | Keep routes grouped under authenticated app only; QA checks internal-only boundary |

---

## Updated Open Choices

Resolved:

- Stack: Next.js + PostgreSQL.
- Language: TypeScript.
- Architecture: modular monolith.
- ORM default: Prisma.
- UI default: Tailwind + shadcn/ui.
- Local DB default: Docker Compose PostgreSQL.
- Auth direction: session-based staff auth.

Still open:

1. Hosting/deployment target.
2. Package manager preference.
3. Exact session storage mechanism.
4. Whether PDF invoices are included in v0 or P1.
5. Whether CSV/Excel export is included in v0 or P1.

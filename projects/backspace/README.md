# Backspace

**Repo**: Not created yet  
**Workspace**: `workspace/backspace/` once implementation repo exists  
**Status**: planning  
**Tier**: P1  
**Product type**: Internal coworking-space management web app  
**Primary language**: Arabic  
**Interface**: RTL

---

## What it is

Backspace is an internal web application for managing a coworking space. It is designed for the owner, managers, reception, and operations staff. The MVP is not customer-facing: visitors/customers do not log in, book directly, or pay through a public portal.

The first release targets one location, while keeping branding and invoice details configurable so the product can later be reused by other coworking spaces under another name.

---

## Current Scope

### In MVP

- Staff authentication and roles.
- Single-location settings.
- Spaces management.
- Internal customer records.
- Hourly daily visits.
- Weekly, biweekly, and monthly subscriptions.
- Internal bookings with conflict prevention.
- Invoices and manual payments.
- Owner/manager dashboard.
- Basic reports.
- QA/security hardening.

### Out of MVP

- Visitor/customer portal.
- Public booking page.
- Online payment gateway.
- Mobile app.
- Multi-location or full multi-tenant support.
- WhatsApp automation.
- Advanced accounting.
- Physical access-control integration.

---

## Who owns it

- **Product**: TBD
- **Tech Lead**: TBD
- **Design**: TBD
- **Stakeholders**: Workspace owner/operator

---

## Tech Stack

Selected stack:

- **App framework**: Next.js
- **Database**: PostgreSQL
- **Language**: TypeScript
- **Architecture**: Modular monolith
- **UI direction**: Arabic RTL internal admin interface

Recommended supporting choices are documented in [Stack Decision](./STACK_DECISION.md).

---

## Key Docs

- [PRD](./PRD.md)
- [Decision Log](./DECISION_LOG.md)
- [Technical Design](./TECHNICAL_DESIGN.md)
- [API Contracts](./API_CONTRACTS.md)
- [Screen Specs](./SCREEN_SPECS.md)
- [Test Plan](./TEST_PLAN.md)
- [Stack Decision](./STACK_DECISION.md)
- [Implementation Defaults](./IMPLEMENTATION_DEFAULTS.md)
- [Repository Setup Runbook](./REPO_SETUP_RUNBOOK.md)
- [Prisma Schema Draft](./PRISMA_SCHEMA_DRAFT.md)
- [Sprint Plan](./SPRINT_PLAN.md)
- [Draft Tracker Issues](./ISSUE_DRAFTS.md)
- [Implementation Backlog](./IMPLEMENTATION_BACKLOG.md)
- [Roadmap](./roadmap.md)
- [QA Checklist](./QA_CHECKLIST.md)
- [Next Steps](./NEXT_STEPS.md)

---

## Key Domain Concepts

- `staff_users` — internal users only, with `passwordHash`, role, and `isActive`.
- `location_settings` — one-location configurable branding and invoice settings.
- `spaces` — rooms, desks, shared areas, and hourly rates.
- `customers` — internal records only; no login.
- `visits` — hourly check-in/check-out usage.
- `subscription_plans` — weekly, biweekly, monthly plans.
- `customer_subscriptions` — customer plan assignments with price snapshots.
- `bookings` — internal reservations with conflict prevention.
- `invoices` — visit/subscription/booking/manual invoices.
- `payments` — manual payment records.
- `audit_logs` — sensitive operational/financial changes.

---

## Recommended First Execution Batch

Start with the first backlog batch from [Implementation Backlog](./IMPLEMENTATION_BACKLOG.md):

1. `BSP-FOUND-001` — Create web app skeleton.
2. `BSP-FOUND-002` — Configure database and migrations.
3. `BSP-FOUND-003` — Build Arabic RTL app shell.
4. `BSP-AUTH-001` — Add staff user model and owner seed.
5. `BSP-AUTH-002` — Implement staff login/logout/session.
6. `BSP-AUTH-003` — Implement location settings.

---

## Portfolio Registry Status

This project has docs under `projects/backspace/` but is not yet registered in `apexyard.projects.yaml` because the implementation repository has not been created yet.

When the repo exists, add a registry entry like:

```yaml
projects:
  - name: backspace
    repo: your-org/backspace
    docs: projects/backspace
    status: active
    tier: P1
```

---

## Recent Activity

- Created product PRD.
- Created technical design.
- Created sprint plan.
- Created QA checklist.
- Created implementation backlog with `BSP-*` item IDs.
- Created MVP roadmap with milestone gates and post-MVP follow-ups.
- Created next-steps handoff for repo setup and first implementation batch.
- Selected Next.js + PostgreSQL as the implementation stack.
- Added implementation defaults: Prisma, Tailwind CSS, shadcn/ui, session-based staff auth, Docker Compose PostgreSQL.
- Added repository setup runbook for the Next.js + PostgreSQL implementation repo.
- Added draft tracker issue pack for implementation milestones.
- Added Prisma/PostgreSQL schema draft for implementation kickoff.
- Added API contracts draft for internal Next.js endpoints.
- Added Arabic RTL screen specifications for MVP pages.
- Added test plan covering unit, integration, E2E smoke, permissions, and Arabic RTL QA.
- Added decision log for durable product and technical decisions.

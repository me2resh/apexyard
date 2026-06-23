# Backspace

**Repo**: https://github.com/zeyadsleem/backspace
**Workspace**: `workspace/backspace/`
**Status**: active
**Tier**: P1

## What It Is

Backspace is an internal staff-only workspace operations management system for a coworking/workspace business. It is used by reception, cashier, supervisor, manager, cleaner, maintenance, and admin staff to manage physical visits, space usage, add-on charges, checkout, internal payments, cleaning, maintenance, tenants, events, memberships, reporting, and auditability.

The core product model is:

```text
Visit -> optional Usage Session -> Charges/Add-ons -> Checkout -> Invoice(s) -> Payment(s) -> Space state update
```

## Product Constraints

- Existing Better-T-Stack app only. Do not scaffold a new app.
- Preserve React + TanStack Router, Hono on Node, tRPC, Better Auth, PostgreSQL, Drizzle ORM, Docker DB setup, Tailwind CSS, shadcn/ui, evlog, lefthook, skills, and Vite+.
- Do not add Next.js or another full-stack framework.
- Do not add a payment provider. Payments are internal records only.
- Do not build standalone POS as the main daily flow. Sales-like activity must be attached as Charges/Add-ons to operational targets.

## Who Owns It

- **Product**: TBD
- **Tech Lead**: TBD
- **Design**: TBD
- **Operations Stakeholders**: receptionist, cashier, supervisor, manager, cleaner, maintenance staff, admin/owner

## Tech Stack

- Package manager: pnpm 10.33.0
- Toolchain: Vite+ via `vp`
- Frontend: React 19, TanStack Router, TanStack Query, TanStack Form
- Backend: Hono on Node
- API: tRPC 11
- Auth: Better Auth
- Database: PostgreSQL with Drizzle ORM
- UI: Tailwind CSS 4, shadcn/ui in `packages/ui`, sonner, lucide-react
- Logging: evlog
- Local DB: Docker Compose under `packages/db/docker-compose.yml`

## Key Links

- PRD: `./prd.md`
- Project map: `./PROJECT_MAP.md`
- Roadmap: `./roadmap.md`
- Initiative: `./initiatives/workspace-operations-management.md`
- Technical design: `./designs/workspace-operations-technical-design.md`
- Architecture index: `./architecture/README.md`
- Architecture vision: `./architecture/vision.md`
- C4 context: `./architecture/context.md`
- C4 container: `./architecture/container.md`
- Data flow diagram: `./architecture/dfd.md`
- Visit checkout sequence: `./architecture/sequence-visit-checkout.md`
- Journey preview source: `./journeys/workspace-operations.yaml`
- Journey preview HTML: `./journeys/workspace-operations.html`
- ApexYard workflow gate checklist: `./workflow-gates.md`
- Filed issue batch: `./ticket-batch.md`

## Tracker

- Parent epic: [zeyadsleem/backspace#3](https://github.com/zeyadsleem/backspace/issues/3)
- Implementation issues: [#4](https://github.com/zeyadsleem/backspace/issues/4)-[#20](https://github.com/zeyadsleem/backspace/issues/20)

## Recent Activity

- 2026-06-23: Registered as an ApexYard-managed project and created planning artefacts.
- 2026-06-23: Added technical design, architecture diagrams, DFD, checkout sequence, journey preview, and SDLC gate checklist before ticket filing.
- 2026-06-23: Created GitHub labels and filed parent epic plus 17 implementation issues.
- 2026-06-23: Synchronized planning direction with the filed issues' operational rich UI policy and optional tool gates.

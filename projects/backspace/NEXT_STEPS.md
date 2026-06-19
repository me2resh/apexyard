# Backspace — Next Steps

## Current State

Backspace planning is complete enough to begin implementation.

Current project docs:

- `projects/backspace/README.md`
- `projects/backspace/PRD.md`
- `projects/backspace/TECHNICAL_DESIGN.md`
- `projects/backspace/SPRINT_PLAN.md`
- `projects/backspace/IMPLEMENTATION_BACKLOG.md`
- `projects/backspace/QA_CHECKLIST.md`
- `projects/backspace/roadmap.md`

Before this next-steps handoff, the Backspace docs package totalled **2074** Markdown lines.

---

## Product Boundary Reminder

Backspace MVP is:

- Internal-only.
- Arabic RTL.
- For one coworking-space location first.
- Used by Owner / Manager / Staff.
- Designed to be reusable later under another brand/name.

Backspace MVP is not:

- A visitor portal.
- A customer login system.
- A public booking system.
- An online payment gateway.
- A multi-location SaaS in v0.

---

## Immediate Decision Needed

The stack is now selected: **Next.js + PostgreSQL**.

Before implementation starts, decide the codebase setup:

### Option A — Create a new implementation repo

Recommended if Backspace will become its own product.

Example future registry entry:

```yaml
projects:
  - name: backspace
    repo: your-org/backspace
    docs: projects/backspace
    status: active
    tier: P1
```

### Option B — Keep planning docs only for now

Recommended if the product idea still needs stakeholder validation before coding.

### Option C — Build inside an existing workspace

Use only if there is already a chosen app repository or platform.

---

## Recommended Next Execution Batch

Start with the first implementation batch from `IMPLEMENTATION_BACKLOG.md`:

1. `BSP-FOUND-001` — Create web app skeleton.
2. `BSP-FOUND-002` — Configure database and migrations.
3. `BSP-FOUND-003` — Build Arabic RTL app shell.
4. `BSP-AUTH-001` — Add staff user model and owner seed.
5. `BSP-AUTH-002` — Implement staff login/logout/session.
6. `BSP-AUTH-003` — Implement location settings.

This creates the first usable internal shell:

- Owner login.
- Protected dashboard shell.
- Arabic RTL layout.
- Configurable location settings.
- Workspace branding and invoice prefix stored outside code.

---

## Sprint 0 Setup Checklist

Before writing product features:

- [ ] Create implementation repo or workspace.
- [x] Choose stack: Next.js + PostgreSQL.
- [ ] Add local development instructions.
- [ ] Add database configuration using Docker Compose PostgreSQL.
- [ ] Add Prisma migration tooling.
- [ ] Add lint/typecheck/test commands.
- [ ] Add Tailwind CSS + shadcn/ui Arabic RTL theme foundation.
- [ ] Add protected internal app layout.

---

## Sprint 1 Setup Checklist

After Sprint 0:

- [ ] Add `staff_users` model/table.
- [ ] Store passwords as `passwordHash` only.
- [ ] Add `isActive` and enforce it during login.
- [ ] Seed initial Owner account safely.
- [ ] Implement `POST /api/auth/login`.
- [ ] Implement `POST /api/auth/logout`.
- [ ] Implement `GET /api/auth/me`.
- [ ] Add `location_settings` model/table.
- [ ] Implement `GET /api/settings/location`.
- [ ] Implement `PATCH /api/settings/location` for Owner only.
- [ ] Build `/login`.
- [ ] Build `/dashboard` shell.
- [ ] Build `/settings/location`.

---

## Handoff Checklist for Engineering

Engineering should read these docs in order:

1. `README.md` — project overview and doc index.
2. `PRD.md` — product scope and user stories.
3. `TECHNICAL_DESIGN.md` — architecture, domain model, APIs, permissions.
4. `SPRINT_PLAN.md` — sprint sequencing and exit criteria.
5. `IMPLEMENTATION_BACKLOG.md` — implementation-ready `BSP-*` work items.
6. `QA_CHECKLIST.md` — launch acceptance and hardening checks.
7. `roadmap.md` — milestone gates and post-MVP follow-ups.

---

## Do Not Start Yet If

- The implementation repo is not chosen.
- There is no owner seed-account strategy.
- There is no database decision.
- Arabic RTL support is not included from the start.
- The team intends to add visitor/customer-facing flows to v0.

---

## First Implementation Definition of Done

The first implementation batch is complete when:

- App runs locally.
- Database migrations run.
- Owner can log in.
- Disabled staff cannot log in.
- `/dashboard` is protected.
- `/settings/location` is Owner-only.
- Location name and invoice prefix are configurable.
- UI is Arabic RTL.
- No public visitor/customer page exists.

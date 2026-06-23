# Backspace Draft Issue Batch

Created: 2026-06-23
Filed: 2026-06-23

These GitHub issues were filed to `zeyadsleem/backspace` on 2026-06-23.

Open issues were later synchronized with a `## Rich UI / Interaction Direction` section so each implementation slice starts with the operational interaction policy in place. Issue #4 is already closed by PR #21; #3 and #5-#20 remain open at the time of this planning sync.

Recommended filing shape:

- Create one parent feature issue for the initiative.
- Create the implementation issues below with `Refs <parent issue>` in each body.
- Default priority: P1 unless the operator changes it.
- Suggested shared labels: `area-product`, `area-ops`, `area-backspace` if those labels exist or are created deliberately.

| Item | Type | Title | Purpose |
|------|------|-------|---------|
| A | Feature | Workspace operations management parent epic | Track the whole Visit-first staff operations initiative and link the PRD/initiative artefacts. |
| B | Feature | Domain foundation: workspace, people, visits, and billing schema | Add Drizzle schema modules for the core workspace operations domain while preserving Better Auth tables. |
| C | Feature | Staff roles, permissions, and branch access | Add role/permission logic on top of Better Auth and enforce it server-side. |
| D | Feature | Money, audit, approvals, and domain rule helpers | Add minor-unit money helpers, audit writer, approval helper, and shared server-side domain constants. |
| E | Feature | Seed workspace operations scenarios | Seed realistic data covering walk-in, member, booking customer, hosted guest, event attendee, unpaid checkout, stock, cleaning, and maintenance scenarios. |
| F | Feature | Staff operations app shell | Build sidebar, topbar, branch selector, shift badge, quick actions, search shell, and PermissionGate. |
| G | Feature | Today operations dashboard | Build the operational dashboard cards and queues for current-day staff work. |
| H | Feature | Live visits and visit details workflow | Build active Visit views, Visit details drawer, status badges, and server-backed visit actions. |
| I | Feature | Space map and availability workflow | Build Space Map, state legend, availability rules, and state-based actions. |
| J | Feature | Walk-in, booking, guest, member, and event check-in drawers | Build staff check-in flows that create Visits and Usage Sessions where required. |
| K | Feature | Add Charge workflow without standalone POS | Build Add Charge drawer and server rules for target-bound charges, stock checks, overrides, discounts, and complimentary reasons. |
| L | Feature | Checkout, invoice split, and internal payments | Build checkout calculation, responsibility split, invoice generation, payment recording, and space-state update. |
| M | Feature | Shifts and cash control | Build open/close shift, cash payment enforcement, expected cash, actual cash, and differences. |
| N | Feature | Calendar bookings and check-in queue | Build calendar/list/timeline views, booking statuses, buffers, deposits, and check-in queue. |
| O | Feature | People, memberships, tenants, and hosted guests | Build people profiles, memberships, tenant/host accounts, guest policy, and host billing workflows. |
| P | Feature | Events and attendee operations | Build event setup, guest lists, attendee check-in, included items, and event/host billing modes. |
| Q | Feature | Catalog, inventory, cleaning, and maintenance operations | Build catalog, stock movement, cleaning queue, and maintenance tickets tied to space state. |
| R | Feature | Reports, staff admin, settings, and audit log | Build daily, occupancy, revenue reports, staff/role settings, and audit log screens. |

## Filed Issues

| Item | Issue | Title |
|------|-------|-------|
| A | [#3](https://github.com/zeyadsleem/backspace/issues/3) | Workspace operations management parent epic |
| B | [#4](https://github.com/zeyadsleem/backspace/issues/4) | Domain foundation: workspace, people, visits, and billing schema |
| C | [#5](https://github.com/zeyadsleem/backspace/issues/5) | Staff roles, permissions, and branch access |
| D | [#6](https://github.com/zeyadsleem/backspace/issues/6) | Money, audit, approvals, and domain rule helpers |
| E | [#7](https://github.com/zeyadsleem/backspace/issues/7) | Seed workspace operations scenarios |
| F | [#8](https://github.com/zeyadsleem/backspace/issues/8) | Staff operations app shell |
| G | [#9](https://github.com/zeyadsleem/backspace/issues/9) | Today operations dashboard |
| H | [#10](https://github.com/zeyadsleem/backspace/issues/10) | Live visits and visit details workflow |
| I | [#11](https://github.com/zeyadsleem/backspace/issues/11) | Space map and availability workflow |
| J | [#12](https://github.com/zeyadsleem/backspace/issues/12) | Walk-in, booking, guest, member, and event check-in drawers |
| K | [#13](https://github.com/zeyadsleem/backspace/issues/13) | Add Charge workflow without standalone POS |
| L | [#14](https://github.com/zeyadsleem/backspace/issues/14) | Checkout, invoice split, and internal payments |
| M | [#15](https://github.com/zeyadsleem/backspace/issues/15) | Shifts and cash control |
| N | [#16](https://github.com/zeyadsleem/backspace/issues/16) | Calendar bookings and check-in queue |
| O | [#17](https://github.com/zeyadsleem/backspace/issues/17) | People, memberships, tenants, and hosted guests |
| P | [#18](https://github.com/zeyadsleem/backspace/issues/18) | Events and attendee operations |
| Q | [#19](https://github.com/zeyadsleem/backspace/issues/19) | Catalog, inventory, cleaning, and maintenance operations |
| R | [#20](https://github.com/zeyadsleem/backspace/issues/20) | Reports, staff admin, settings, and audit log |

## Draft Parent Body

```markdown
## User Story

As an admin/owner, I want a Visit-first internal operations system for the workspace so that staff can manage arrivals, space usage, contextual charges, checkout, payments, facilities, reports, and auditability without standalone POS.

## Acceptance Criteria

- [ ] PRD exists at `projects/backspace/prd.md`.
- [ ] Initiative exists at `projects/backspace/initiatives/workspace-operations-management.md`.
- [ ] The existing Better-T-Stack foundation remains intact.
- [ ] Implementation issues are linked from this parent.

## Design Notes

See `projects/backspace/PROJECT_MAP.md` and `projects/backspace/roadmap.md` in the ApexYard ops repo.

## Out of Scope

- New app scaffold.
- Replacement of TanStack Router, Hono, tRPC, Better Auth, Drizzle, PostgreSQL, pnpm, Vite+, Tailwind, or shadcn/ui.
- External payment provider.
- Customer portal.
- Standalone anonymous POS as the normal workflow.

## Glossary

| Term | Definition |
|------|------------|
| Visit | Record for every physical person entering the workspace. |
| Usage Session | Billable or covered occupation of a specific space during a Visit. |
| Charge | Add-on, product, service, fee, discount, or complimentary item attached to an operational target. |

## Rich UI / Interaction Direction

- Rich UI means operational clarity, fast staff actions, visible state, keyboard-friendly flows, and polished feedback. It does not mean marketing effects or decorative motion.
- Default visual system stays Tailwind CSS + shadcn/ui in the existing React/TanStack Router app.
- Candidate UI tools are allowed only when a child issue needs them: `motion`, `cmdk`, `@tanstack/react-table`, `recharts`, `@dnd-kit/*`, and `dotLottie`.
- Every implementation PR that adds a persistent UI dependency must explain why it is needed and include an AgDR when it is a product or architecture decision.
```

## Draft Child Body Template

```markdown
## User Story

As a staff operator, I want {capability} so that {operational benefit}.

## Acceptance Criteria

- [ ] {primary acceptance criterion}
- [ ] Server-side rules are enforced through tRPC procedures/domain services where relevant.
- [ ] UI follows the existing TanStack Router and shadcn/ui conventions.
- [ ] `vp check` and relevant build/test commands pass or documented gaps are captured.

## Design Notes

See `projects/backspace/prd.md`, `projects/backspace/PROJECT_MAP.md`, and `projects/backspace/initiatives/workspace-operations-management.md`.

## Out of Scope

- Stack replacement.
- External payment provider.
- Standalone anonymous POS.

## Glossary

| Term | Definition |
|------|------------|
| Visit | Record for every physical person entering the workspace. |
| Charge | Contextual add-on or adjustment attached to a visit/session/event/host/invoice draft. |

## Rich UI / Interaction Direction

- Add issue-specific guidance for forms, tables, command/search, reports/charts, motion, drag/drop, or empty/success states.
- Keep optional tools gated by real workflow need: `motion`, `cmdk`, `@tanstack/react-table`, `recharts`, `@dnd-kit/*`, `dotLottie`.
- Prefer TanStack Form, TanStack Query/tRPC, TanStack Router, Tailwind, and shadcn/ui before adding new dependencies.
```

## Filed Rich UI / Interaction Direction Summary

| Issue | Direction |
|-------|-----------|
| [#3](https://github.com/zeyadsleem/backspace/issues/3) | Product-wide policy: rich UI means operational clarity; optional tools are allowed only per workflow need. |
| [#5](https://github.com/zeyadsleem/backspace/issues/5) | Permissions should make authority visible with clear disabled-state explanations and table/matrix interactions when needed. |
| [#6](https://github.com/zeyadsleem/backspace/issues/6) | Domain helpers should return UI-friendly reason codes for approval, denial, money validation, and audit-sensitive states. |
| [#7](https://github.com/zeyadsleem/backspace/issues/7) | Seed data must cover realistic UI density and states: busy, empty, overdue, blocked, approval-required, pay-later, complimentary, facilities, and shift discrepancy. |
| [#8](https://github.com/zeyadsleem/backspace/issues/8) | App shell establishes the staff-console feel; `cmdk` and `motion` are allowed only for real quick actions and purposeful transitions. |
| [#9](https://github.com/zeyadsleem/backspace/issues/9) | Today dashboard emphasizes operational state, loading/empty/error/stale states, and uses `recharts` only for real charts. |
| [#10](https://github.com/zeyadsleem/backspace/issues/10) | Live visits prioritize scanability; use `@tanstack/react-table` if sorting/filtering/selection/pagination are central. |
| [#11](https://github.com/zeyadsleem/backspace/issues/11) | Space map uses accessible state distinctions and meaningful motion, with a list/table fallback for dense or small screens. |
| [#12](https://github.com/zeyadsleem/backspace/issues/12) | Check-in drawers use guided forms, progressive disclosure, inline validation, and immediate next actions. |
| [#13](https://github.com/zeyadsleem/backspace/issues/13) | Add Charge reinforces target-bound/no-POS behavior; `cmdk` is allowed for fast catalog/fee/discount search. |
| [#14](https://github.com/zeyadsleem/backspace/issues/14) | Checkout is rich but calm: split, responsibility, payment state, zero-due/included/pay-later, and space-state outcome must be clear. |
| [#15](https://github.com/zeyadsleem/backspace/issues/15) | Shifts emphasize trust, reconciliation, discrepancy handling, audit trail, and deliberate close-shift states. |
| [#16](https://github.com/zeyadsleem/backspace/issues/16) | Calendar/bookings balance time clarity and reception speed; avoid scheduler dependency until simple layouts prove insufficient. |
| [#17](https://github.com/zeyadsleem/backspace/issues/17) | People/members/tenants are operational records, not generic CRM; reuse app-shell search if introduced. |
| [#18](https://github.com/zeyadsleem/backspace/issues/18) | Events need fast attendee operations and may use `@tanstack/react-table` for sorting/filtering/bulk attendee work. |
| [#19](https://github.com/zeyadsleem/backspace/issues/19) | Catalog/inventory/facilities focus on triage; `@dnd-kit/*` only for real reorder/assignment workflows. |
| [#20](https://github.com/zeyadsleem/backspace/issues/20) | Reports/admin use `@tanstack/react-table` and `recharts` when they answer real management/audit questions, not vanity dashboards. |

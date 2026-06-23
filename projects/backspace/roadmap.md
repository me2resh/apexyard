# Backspace Roadmap

Created: 2026-06-23
Last updated: 2026-06-23

## Current Initiative

| Initiative | Status | Source |
|------------|--------|--------|
| Workspace Operations Management | Draft | `initiatives/workspace-operations-management.md` |

## Phase Plan

| Phase | Name | Objective | Depends On | Status |
|-------|------|-----------|------------|--------|
| 0 | Repository inspection | Confirm Better-T-Stack structure, scripts, DB, auth, tRPC, routes, env, Docker, shadcn locations | None | Done for planning |
| 1 | Domain foundation | Schema, constants, Zod schemas, money helper, permissions, audit helper, seed data | Phase 0 | Filed; schema complete via #4/PR #21 |
| 2 | App shell | Staff sidebar, topbar, branch selector, shift badge, global search shell, PermissionGate | Phase 1 | Filed |
| 3 | Operations MVP | Today, Live Visits, Space Map, drawers for visit/check-in/add-charge/checkout | Phases 1-2 | Filed |
| 4 | Billing foundation | Open bills, invoice generation, internal payment records, shift open/close | Phase 3 | Filed |
| 5 | People, tenants, events | People profiles, memberships, tenant hosts, hosted guests, events and attendees | Phase 4 | Filed |
| 6 | Inventory, cleaning, maintenance | Catalog, stock movements, cleaning queue, maintenance tickets | Phase 4 | Filed |
| 7 | Reports and admin | Daily, occupancy, revenue reports, staff roles, settings, audit log | Phases 5-6 | Filed |

## Release Slices

| Slice | Outcome | Candidate Issues |
|-------|---------|------------------|
| Foundation | Data model and server rules are ready for UI work | #4, #5, #6, #7 |
| Staff Console | Staff can navigate the app and see operational context | #8, #9 |
| Operations MVP | Reception/cashier can run daily visit workflows | #10, #11, #12, #13, #14 |
| Billing Control | Cashier/manager can close invoices and shifts safely | #14, #15 |
| Business Coverage | Members, tenants, hosted guests, and event attendees are supported | #16, #17, #18 |
| Facilities | Workspace readiness is visible and actionable | #19 |
| Management | Owner/admin gets reports, settings, roles, and audit | #20, plus #5 for role infrastructure |

## Interaction Policy Across Slices

- Existing stack first: React, TanStack Router, TanStack Query, TanStack Form, Tailwind, shadcn/ui, tRPC.
- Optional tools are gated per issue and PR: `motion`, `cmdk`, `@tanstack/react-table`, `recharts`, `@dnd-kit/*`, `dotLottie`.
- Forms, tables, command/search, charts, motion, and drag/drop must serve staff operations, not decoration.

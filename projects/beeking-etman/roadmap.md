# Beeking Etman — Product Roadmap

> **Last updated:** 2026-06-05 (RM-002 shipped)
> **Owner:** @zeyadsleem (Tech Lead)
> **Source of truth:** `architecture/vision.md` § "Migration path" — re-evaluate every quarterly review.
> **Anti-scope:** see `architecture/vision.md` § "Things we explicitly chose NOT to build" (13 items, all with "reconsider when" triggers).
> **Decisions:** AgDRs in [`workspace/beeking-etman/docs/agdr/`](https://github.com/zeyadsleem/beeking-etman/tree/main/docs/agdr) — AgDR-0001 (monorepo architecture) is the only one so far.

## Now (Q3 26 — current cycle)

P0 items in flight this quarter. Each maps to one or more tickets in `zeyadsleem/beeking-etman` issues (filed via `/tickets-batch`).

| ID | Item | Priority | Status | Owner | Notes |
|----|------|----------|--------|-------|-------|
| RM-001 | Restructure beeking-etman into pnpm-workspaces monorepo (`apps/storefront`, `apps/backend`, `packages/*`) | P0 | **shipped** · [#1](https://github.com/zeyadsleem/beeking-etman/issues/1) · [PR #6](https://github.com/zeyadsleem/beeking-etman/pull/6) · [commit `3aad8ed`](https://github.com/zeyadsleem/beeking-etman/commit/3aad8edb714d8b4a4cd5c534462da5dbe6fe30d4) | @zeyadsleem | Chore. Per [AgDR-0001](https://github.com/zeyadsleem/beeking-etman/blob/main/docs/agdr/AgDR-0001-monorepo-architecture.md). First implementation step; everything else is gated on it. **Merged 2026-06-05.** |
| RM-002 | Stand up Medusa `apps/backend` skeleton (PostgreSQL + Redis + Medusa + worker) | P0 | **shipped** · [#2](https://github.com/zeyadsleem/beeking-etman/issues/2) · [PR #8](https://github.com/zeyadsleem/beeking-etman/pull/8) · [commit `4272655`](https://github.com/zeyadsleem/beeking-etman/commit/4272655aad8704a1e85572a4217d70d73430a8d3) | @zeyadsleem | Chore. `medusa develop` + `tsc --noEmit` + `medusa exec seed` smoke pass. **Merged 2026-06-05.** `medusa build` AC deferred to [#7](https://github.com/zeyadsleem/beeking-etman/issues/7) (RM-006 spike — upstream Medusa 2.4.0 pnpm-monorepo bug). |
| RM-003 | Local docker-compose stack (postgres + redis + medusa-backend + medusa-worker + storefront) | P0 | implemented locally · pending PR · [#3](https://github.com/zeyadsleem/beeking-etman/issues/3) | @zeyadsleem | Chore. `infra/docker-compose.yml`, override, Dockerfile, healthchecks, Makefile, seed, and `make ping` verified. Mirrors prod infra in `infra/`. |
| RM-004 | Storefront hits Medusa `/store/products` and renders an Arabic product list | P0 | implemented locally · pending PR · [#4](https://github.com/zeyadsleem/beeking-etman/issues/4) | @zeyadsleem | Feature. Uses Medusa DTC starter commerce flows per AgDR-0002; `/products` compatibility route and Playwright product-list test added. |
| RM-005 | Split LICENSE to acknowledge Medusa AGPL-3.0 in `apps/backend` (root stays MIT) | P0 | implemented locally · pending PR · [#5](https://github.com/zeyadsleem/beeking-etman/issues/5) | @zeyadsleem | Chore. Component license split added. Note: installed `@medusajs/medusa@2.15.5` package metadata reports MIT; backend application license is AGPL-3.0-or-later per ticket. |

## Next (Q4 26 → Q1 27 — 1–3 cycles out)

| ID | Item | Priority | Status | Owner | Notes |
|----|------|----------|--------|-------|-------|
| RM-006 | Arabic + RTL UI on real Medusa products | P0 | not-started | – | Feature. Tokenise all strings; full RTL; EGP pricing. |
| RM-007 | Design system in Storybook (Button, Input, Select, Checkbox, Radio, Modal, Drawer, Product Card, Price Display, Quantity Selector, Cart Item, Checkout Step, Badge, Alert, Navbar, Footer, Breadcrumb, Tabs) | P0 | not-started | – | Feature. All components reusable · accessible · RTL-ready · themeable · documented. |
| RM-008 | Product listing page + product details page | P0 | not-started | – | Feature. Mobile-first; readable slugs. |
| RM-009 | Cart page + add-to-cart + cart line item management | P0 | not-started | – | Feature. Uses Medusa cart API (no custom cart logic — see anti-scope). |
| RM-010 | Readable product slugs + basic SEO meta (Arabic meta titles, descriptions) | P1 | not-started | – | Feature. |
| RM-011 | Responsive mobile-first UX | P0 | not-started | – | Feature. Tested on iPhone 12 + Pixel 5 viewports. |
| RM-012 | Checkout completes a real order end-to-end on staging | P0 | not-started | – | Feature. E2E Playwright test. |
| RM-013 | Paymob payment provider integration (test mode) | P0 | not-started | – | Feature. Webhook signature verification. |
| RM-014 | Cash on Delivery as Medusa manual-capture payment method | P0 | not-started | – | Feature. |
| RM-015 | Governorate-based shipping zones + EGP price lists + free-shipping threshold | P0 | not-started | – | Feature. |
| RM-016 | Order appears in Medusa Admin (v1 admin via Medusa Admin, not custom) | P0 | not-started | – | Feature. Confirms the integration works. |

## Later (Q2 27 → Q3 27 — 3+ cycles out)

| ID | Item | Priority | Status | Owner | Notes |
|----|------|----------|--------|-------|-------|
| RM-017 | Customer register / login | P1 | not-started | – | Feature. Medusa customer API. |
| RM-018 | Customer order history page | P1 | not-started | – | Feature. |
| RM-019 | Arabic transactional email templates | P1 | not-started | – | Feature. Order confirmation, shipping notification, etc. |
| RM-020 | Production VPS deploy (Ubuntu + Docker + Nginx + SSL) | P0 | not-started | – | Chore. Hardening. |
| RM-021 | Production backups (PostgreSQL dumps, Medusa uploads) | P0 | not-started | – | Chore. Daily, with off-site copy. |
| RM-022 | Production monitoring (uptime check, error tracking) | P1 | not-started | – | Chore. OpenTelemetry already in boilerplate. |
| RM-023 | Bug-fix week, performance pass | P1 | not-started | – | Buffer. |
| RM-024 | `/launch-check` (10-dimension audit: security, a11y, compliance, analytics, SEO, GEO, perf, monitoring, docs, behaviour-quality) | P0 | not-started | – | Chore. Pre-launch gate. |
| RM-025 | Security review (payments + webhooks) | P0 | not-started | – | Chore. Pre-launch gate. |
| RM-026 | Accessibility audit (WCAG 2.1 AA) | P0 | not-started | – | Chore. Pre-launch gate. |

## Done

| ID | Item | Shipped | PR |
|----|------|---------|-----|
| RM-000 | Project foundation filed (`projects/beeking-etman/foundation.md`, `architecture/vision.md`, `README.md`, `apexyard.projects.yaml` registered) | 2026-06-04 | – |
| RM-000a | `/setup` bootstrap (onboarding.yaml, LSP enabled, typescript-language-server installed, `ENABLE_LSP_TOOL=1` set in `~/.zshrc`) | 2026-06-04 | – |
| RM-000b | `workspace/beeking-etman/` cloned from `zeyadsleem/beeking-etman` (next-enterprise boilerplate as starting point) | 2026-06-05 | – |
| RM-000c | AgDR-0001: monorepo architecture | 2026-06-05 | – |
| RM-000d | `/tickets-batch` Q3 26 "Now" filed: [#1](https://github.com/zeyadsleem/beeking-etman/issues/1) monorepo restructure, [#2](https://github.com/zeyadsleem/beeking-etman/issues/2) Medusa skeleton, [#3](https://github.com/zeyadsleem/beeking-etman/issues/3) docker-compose, [#4](https://github.com/zeyadsleem/beeking-etman/issues/4) Arabic product list, [#5](https://github.com/zeyadsleem/beeking-etman/issues/5) LICENSE split | 2026-06-05 | – |
| RM-000e | RM-001 shipped: monorepo restructure, [PR #6](https://github.com/zeyadsleem/beeking-etman/pull/6) merged to `main` (squash-merge commit `3aad8ed`); storefront lives at `apps/storefront/`; pnpm workspaces enabled; AgDR-0001 implementation complete | 2026-06-05 | [PR #6](https://github.com/zeyadsleem/beeking-etman/pull/6) |
| RM-000f | RM-002 shipped: Medusa `apps/backend` skeleton, [PR #8](https://github.com/zeyadsleem/beeking-etman/pull/8) merged to `main` (squash-merge commit `4272655`); `medusa develop` + `tsc --noEmit` + `medusa exec seed` smoke pass; `medusa build` AC deferred to [#7](https://github.com/zeyadsleem/beeking-etman/issues/7) (RM-006 spike — upstream Medusa 2.4.0 pnpm-monorepo bug) | 2026-06-05 | [PR #8](https://github.com/zeyadsleem/beeking-etman/pull/8) |

---

_Generated as part of the project bootstrap. Re-run `/roadmap` to update; new items filed via `/feature`, `/chore`, `/refactor`, or `/tickets-batch`._

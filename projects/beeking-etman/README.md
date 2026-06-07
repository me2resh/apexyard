# Beeking Etman

**Repo**: https://github.com/zeyadsleem/beeking-etman
**Workspace**: workspace/beeking-etman/
**Status**: active
**Tier**: P0

## What it is

Production-grade Arabic-first e-commerce platform for the Egyptian market. Built on a **Next.js Enterprise** frontend, **Medusa** commerce backend, and self-hosted infrastructure (PostgreSQL + Redis + Docker + Nginx). Arabic + RTL first; EGP pricing; Paymob + Cash on Delivery for payments. Single primary repo, fully owned by the project — no SaaS / Medusa Cloud dependency.

## Who owns it

- **Tech Lead**: @zeyadsleem
- **Product**: @zeyadsleem
- **Stakeholders**: @zeyadsleem

## Tech stack

| Layer | Choice |
|---|---|
| Frontend | Next.js (App Router) — based on `Blazity/next-enterprise` boilerplate |
| Commerce Backend | Medusa (self-hosted) |
| Admin | Medusa Admin (out of the box for MVP) |
| Database | PostgreSQL |
| Cache / Jobs | Redis |
| Payments | Cash on Delivery (MVP) + Paymob (MVP) → + Fawry (later) |
| Shipping | Egypt-first, governorate-based zones |
| Design System | Tailwind CSS + Radix UI + CVA + Storybook |
| Testing | Vitest + React Testing Library + Playwright |
| Hosting | Self-hosted (Ubuntu + Docker + Nginx + SSL) |
| CI/CD | GitHub Actions |
| L10n | Arabic first; English-ready; full RTL |
| Currency | EGP |

## Repository strategy

| Repo | Role |
|---|---|
| `zeyadsleem/beeking-etman` | **Source of Truth.** Frontend + storefront + project docs. |
| `medusajs/dtc-starter` | **Commerce reference only.** Read-only model for storefront commerce flows. |
| `Blazity/next-enterprise` | **Engineering reference only.** Architectural / tooling reference. |

In case of conflict: `beeking-etman` wins. Medusa and the boilerplate are reference material — neither is the primary repo.

## Reference sources

- [Medusa Documentation](https://docs.medusajs.com) — commerce features, deployment, modules, admin extensions
- [Next.js Enterprise Boilerplate](https://github.com/Blazity/next-enterprise) — frontend engineering reference
- [Medusa DTC Starter](https://github.com/medusajs/dtc-starter) — storefront commerce flow reference

## Key links

- Production: _not yet deployed_
- Staging: _not yet deployed_
- Monitoring: _TBD_
- Runbook: _TBD_

## Recent activity

- Initial project foundation filed (this folder)
- Architecture vision drafted at [`architecture/vision.md`](architecture/vision.md)
- MVP scope documented at [`foundation.md`](foundation.md)
- Next step: bootstrap workspace clone, generate first MVP tickets

## Apexyard role

This project is managed via the **apexyard** ops fork. Apexyard is the *development methodology* (planning, docs, code review, release) — **not** a feature of the product. Nothing in apexyard ships to customers.

## Active methodology (apexyard-driven)

1. Read docs first (Medusa, Next.js, existing code, dtc-starter reference)
2. Reuse before build — never reimplement cart / checkout / order / inventory / pricing / discount / customer logic
3. Create technical plan (AgDR for arch decisions)
4. Implement
5. Test (unit + integration + E2E for checkout)
6. Update docs
7. Commit (Conventional Commits) → PR (Rex review → CEO approval → merge)

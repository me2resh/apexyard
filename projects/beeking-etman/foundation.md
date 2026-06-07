# Beeking Etman — Project Foundation & SRS

> **Source of truth.** This document is the comprehensive project foundation. The curated architecture vision (target-state + migration path + anti-scope) is extracted at [`architecture/vision.md`](architecture/vision.md) for the `/tech-vision` workflow. This file is the broader spec — scope, strategy, MVP, non-goals, quality standards, security, SEO, environments.
>
> **Audience:** tech leads, engineering, product, anyone onboarding to the project.
> **Status:** v1 — initial filing. Update via PR when scope or strategy changes.
> **Last reviewed:** 2026-06-04

## 1. Project Identity

**Beeking Etman** is an Arabic-first e-commerce platform for the Egyptian market.

**Primary repository:** `zeyadsleem/beeking-etman`

This repository is the **source of truth**. All code, docs, tests, and deployment configs live here.

`beeking-etman` was originally cloned from **Next.js Enterprise Boilerplate** (Blazity/next-enterprise), but as of project adoption it is its own project — the boilerplate is now an **engineering reference only**.

---

## 2. Core Project Decision

Beeking Etman is **not** built from scratch as a full e-commerce platform.

**Final decision:** Beeking Etman = Next.js Enterprise Frontend + Full Medusa Commerce Backend + Arabic/Egypt Customization.

| Decision | Status |
|---|---|
| Build a custom cart engine from scratch | ❌ Rejected — use Medusa |
| Build a custom order system from scratch | ❌ Rejected — use Medusa |
| Build a custom inventory system from scratch | ❌ Rejected — use Medusa |
| Build a custom admin dashboard from scratch (v1) | ❌ Rejected — use Medusa Admin for v1 |
| Copy Medusa DTC Starter wholesale on top of current project | ❌ Rejected — would break `beeking-etman` structure |
| Break the existing `beeking-etman` architecture | ❌ Rejected |

**Core rule:** Use Medusa for commerce. Use Beeking Etman for the storefront and engineering foundation. Build custom code only where it adds business value.

---

## 3. Repository Strategy

### 3.1 Primary Repository

`zeyadsleem/beeking-etman` owns:

- Frontend application
- Storefront experience
- Arabic UI + RTL
- Design system
- UI components
- SEO + Localization
- Testing + CI/CD
- Deployment configuration
- Project documentation

Every architectural or development decision lives here.

### 3.2 Repository Origin

Cloned from `Blazity/next-enterprise` — the **engineering reference** going forward. Used to understand structure, standards, and best practices.

### 3.3 Commerce Reference Repository

`medusajs/dtc-starter` is a **reference for commerce flows**:

- Medusa integration patterns
- Storefront commerce flows
- Cart / checkout / customer accounts / order history
- Payment flow
- Shipping flow
- Medusa project structure

It is **not** the primary repo.

### 3.4 Source of Truth Rule

If `Blazity/next-enterprise`, `medusajs/dtc-starter`, and `beeking-etman` disagree: **`beeking-etman` wins.**

---

## 4. Official Reference Sources

| Domain | Source |
|---|---|
| Commerce (Medusa) | [Medusa Documentation](https://docs.medusajs.com) |
| Frontend engineering | [Next.js Enterprise Boilerplate](https://github.com/Blazity/next-enterprise) |
| Commerce flow reference | [Medusa DTC Starter](https://github.com/medusajs/dtc-starter) |

**Medusa documentation** is the official reference for Medusa server, admin, products, orders, customers, inventory, pricing, promotions, payments, shipping, workflows, modules, API, admin extensions, and deployment. Medusa requires PostgreSQL + Redis in production — this is the reason for the self-hosted infrastructure decision (no Medusa Cloud).

---

## 5. Architecture Strategy

### 5.1 High-Level Architecture

```
Beeking Etman
├── Storefront    →  Next.js frontend (based on beeking-etman)
├── Commerce Backend  →  Medusa backend
└── Admin         →  Medusa Admin
```

Medusa cleanly separates the Medusa application from the storefront. The storefront is a separate app using the project's chosen technology.

### 5.2 Recommended Monorepo Structure

```
beeking-etman/
├── apps/
│   ├── storefront/        Next.js storefront based on current beeking-etman
│   └── backend/           Medusa backend
├── packages/
│   ├── ui/
│   ├── config/
│   └── shared/
├── infra/
│   ├── docker/
│   ├── nginx/
│   └── deployment/
├── docs/                  project documentation
└── .github/workflows/
```

---

## 6. Frontend Strategy

### 6.1 Frontend Foundation

The frontend lives inside `beeking-etman`. Preserves the Next.js Enterprise foundation:

- Next.js App Router
- TypeScript Strict Mode
- Tailwind CSS
- Radix UI
- CVA
- Storybook
- ESLint + Prettier
- Vitest
- React Testing Library
- Playwright
- GitHub Actions
- OpenTelemetry
- Bundle Analyzer
- Environment validation

No fresh Next.js project will be created.

### 6.2 Storefront Requirements

Homepage · Product listing · Product details · Cart · Checkout · Customer login · Customer register · Customer account · Order history · Static pages · Search · Arabic SEO · Responsive · Mobile-first.

### 6.3 Arabic & RTL Requirements

Arabic-first. Full RTL. EGP pricing. Arabic validation messages. Arabic SEO pages. Readable slugs. English-ready without rebuild.

---

## 7. Backend Strategy

### 7.1 Medusa as Full Commerce Backend

Medusa is the primary commerce platform — not a thin API layer. Owns:

Products · Variants · Collections · Categories · Inventory · Pricing · Promotions · Discounts · Cart · Checkout · Customers · Orders · Shipping · Payments · Workflows.

### 7.2 Medusa Admin

Medusa Admin is the v1 admin dashboard. Owns product / category / order / customer / inventory / discount / shipping / payment operations. **No custom admin dashboard in v1.**

### 7.3 Backend Customization Scope

- Paymob payment provider
- Cash on Delivery
- Fawry (later)
- Egyptian shipping rules
- Governorate-based shipping
- Arabic transactional email templates (later)
- Custom order statuses (as needed)
- Tax rules (as needed)
- Admin extensions (as needed)

---

## 8. Self-Hosted Strategy

### 8.1 No Medusa Cloud

- Lower cost
- Full infra ownership
- Full data control
- Full customization freedom
- No paid-service dependency
- Hosting-portable

Medusa documents the self-hosting path explicitly.

### 8.2 Target Infrastructure

```
Ubuntu Server
Docker
PostgreSQL
Redis
Medusa Backend
Medusa Admin
Next.js Storefront
Nginx Reverse Proxy
SSL
GitHub Actions
Object Storage
CDN (later)
Backups
Monitoring
```

### 8.3 Production Services

```
services/
├── postgres
├── redis
├── medusa-backend
├── medusa-worker
├── storefront
└── nginx
```

Single VPS at first. Later: separate database, cache, frontend hosting, CDN, object storage, monitoring stack.

---

## 9. Payments Strategy

### 9.1 MVP

- Cash on Delivery
- Paymob

### 9.2 Later

Fawry · Bank Transfer · Wallets (if market needs them).

### 9.3 Payment Rules

- No card data stored in the system. All card processing via the payment provider.
- Support: success callback · failure handling · webhooks · order status sync · secure secrets in backend only.

---

## 10. Shipping Strategy

Egypt-first. Governorate-based pricing. Free-shipping threshold. Multiple shipping methods (later). Shipment status tracking. Carrier API integrations (later).

---

## 11. Design System Strategy

Built inside `beeking-etman`. Built on:

- Tailwind CSS
- Radix UI
- CVA
- Storybook
- Design tokens

**Core components:** Button · Input · Select · Checkbox · Radio · Modal · Drawer · Product Card · Price Display · Quantity Selector · Cart Item · Checkout Step · Badge · Alert · Navbar · Footer · Breadcrumb · Tabs.

Every component must be reusable · accessible · RTL-ready · themeable · documented in Storybook.

---

## 12. MVP Scope

### 12.1 Included in MVP

Arabic storefront · Full RTL · Homepage · Product listing · Product details · Cart · Checkout · Customer account · Order history · Cash on Delivery · Paymob · Medusa Admin · Product / order / customer management · Basic coupons · Egyptian shipping zones · SEO basics · Production deployment · Docker-based self-hosting · GitHub Actions basics.

### 12.2 Not Included in MVP

Marketplace · Multi-vendor · Mobile app · Loyalty system · Advanced ERP integration · Full custom admin dashboard · Full Arabic Medusa Admin · Advanced analytics · AI product recommendations · AI search · AI chatbot · AI customer support · AI personalization.

---

## 13. Explicit AI Non-Goals

The product contains **no AI features visible to end users**. Specifically excluded:

- AI Chatbot
- AI Search
- AI Product Recommendations
- AI Customer Support
- AI Content Generation
- AI Personalization
- AI Agents inside the product
- Any end-user-facing capability labelled as AI

Any future AI feature is a new requirement, not in scope of the current project.

---

## 14. Apexyard Development Methodology

### 14.1 Apexyard's Role

Apexyard is the **development methodology and management layer** for this project. It is:

- ❌ Not part of the product
- ❌ Not visible to users
- ❌ Not a feature in the store

It is used for: planning · analysis · documentation · architecture design · code organization · refactoring · QA · repository management · development workflow.

### 14.2 Development Workflow

Every task follows:

1. Read documentation
2. Analyze existing code
3. Create technical plan
4. Implement
5. Create tests
6. Update documentation
7. Commit (Conventional Commits)
8. Create Pull Request

---

## 15. GitHub CLI Strategy

`gh` is installed and used in the dev environment for:

- Clone repositories
- Manage branches
- Create pull requests
- Create issues
- Review repo status
- Manage releases
- Manage workflows

`gh` is a developer tool only — it is not part of the product.

---

## 16. Development Rules

### 16.1 Read Docs First

Before any feature:

- Medusa Docs
- Next.js / Next Enterprise Docs
- Existing code inside `beeking-etman`
- Comparable implementations inside `medusajs/dtc-starter`
- Design the solution
- Implement
- Test
- Document

### 16.2 Reuse Before Build

**Never re-implement** (Medusa provides them):

- Cart logic · Checkout logic · Order logic · Inventory logic · Pricing logic · Discount logic · Customer logic · Payment workflow · Shipping workflow

Customize on top of Medusa. Do not work around it.

### 16.3 Architecture Safety

**Forbidden:**

- Breaking the Next Enterprise structure inside `beeking-etman`
- Breaking Medusa module structure
- Adding dependencies without a clear reason
- Bypassing TypeScript Strict Mode
- Putting payment secrets in the frontend
- Hardcoding Arabic strings without a localization structure
- Building undocumented, non-reusable components
- Implementing checkout outside Medusa without strong justification
- Skipping tests on checkout/payment flows

---

## 17. Quality Standards

Every new code commit must meet:

- TypeScript Strict
- ESLint clean
- Prettier clean
- Conventional Commits
- Unit tests for important logic
- Integration tests when needed
- E2E tests for checkout
- Storybook for core components
- Environment variable validation
- Secure secrets handling
- Logging
- Error monitoring (later)
- Backup strategy

---

## 18. Environments

```
local
development
staging
production
```

Each environment has its own:

- Environment variables
- Database (or schema, per stage)
- Payment credentials
- Logging
- Deployment flow

No dangerous change is tested directly on production.

---

## 19. Security Requirements

HTTPS · Secure cookies · Input validation · Rate limiting on sensitive operations · Webhook signature verification · Environment secrets · No secrets in the frontend · Role-based admin access (Medusa native) · Database backups · Dependency updates · Basic firewall rules on the server · Nginx reverse proxy hardening.

---

## 20. SEO Requirements

Arabic meta titles · Arabic meta descriptions · Product structured data · Open Graph · Sitemap · robots.txt · Canonical URLs · Readable product slugs · Fast page loading · Optimized images.

---

## 21. Final Implementation Direction

```
Beeking Etman
├── Primary Repository     zeyadsleem/beeking-etman
├── Frontend               Next.js Enterprise-based storefront
├── Commerce Backend       Medusa
├── Commerce Reference     medusajs/dtc-starter
├── Admin                  Medusa Admin
├── Payments               COD + Paymob  → + Fawry (later)
├── Database               PostgreSQL
├── Cache / Jobs           Redis
├── Infrastructure         Ubuntu + Docker + Nginx + SSL
├── Methodology            Apexyard
├── Tooling                GitHub CLI (gh)
└── Market                 Arabic First / Egypt First
```

---

## 22. Final Statement

**Beeking Etman is not an e-commerce project built from scratch.**

It is a professional Arabic e-commerce platform built on:

- `zeyadsleem/beeking-etman` as the source of truth
- Next.js Enterprise as the engineering foundation
- Medusa as the full commerce backend
- `medusajs/dtc-starter` as a reference for commerce integration
- Self-hosted infrastructure (no Medusa Cloud)
- PostgreSQL + Redis + Docker + Nginx as the operational base
- Paymob + Cash on Delivery for the Egyptian market
- Apexyard as the development methodology
- No AI features in the product

**End state:** Production-grade, Arabic-first, Egypt-first, fully self-hosted, maintainable, extensible, fully owned by the project.

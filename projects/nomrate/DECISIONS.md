# Nomrate — Grill Decision Record

Locked during `/grill-me` session, June 2026. Supersedes OBSIDIAN codename in user-facing copy.

## Brand

| Field | Value |
|-------|--------|
| **Name** | Nomrate |
| **Tagline** | Know your market rate. |
| **Domains** | `nomrate.com`, `nomrate.app` |
| **Bundle ID** | `app.nomrate.mobile` |
| **Ticket prefix** | `NOM` |

## Product scope

Full product — all features F1–F14:

- **Phase 1A:** Smart rate calculator, market dashboard, platform fee calculator, vibe coder guide, onboarding rate reveal
- **Phase 1B:** Contracts, proposals, invoices, client pipeline, content library
- **Phase 2:** AI rate advisor, AI doc pre-fill, earnings dashboard
- **Phase 3:** Rate transparency board, template marketplace

## Architecture

| Area | Decision |
|------|----------|
| **Repos** | Three: `nomrate-mobile`, `nomrate-api`, `nomrate-web` |
| **Shared logic** | Private npm `@nomrate/rates-core` (published from API repo) |
| **Mobile** | Expo + TypeScript + Expo Router, Zustand, MMKV, i18next |
| **API** | AWS CDK (TypeScript), Lambda, API Gateway, DynamoDB single-table |
| **Region** | `me-south-1` (Bahrain) + CloudFront where applicable |
| **Auth** | Auth0 (Google, Apple, email) |
| **AI (Pro+)** | Claude Haiku via Lambda proxy, 50 calls/day |
| **Analytics** | PostHog + Sentry |
| **PDFs** | HTML templates → `expo-print` |
| **Mobile deploy** | EAS Build + EAS Submit |
| **Offline** | Offline-first core; MMKV + sync queue |
| **Testing** | Business-logic heavy (>90% on `rates-core`, integration tests on API, Maestro/Playwright on critical paths) |

## Data

| Area | Decision |
|------|----------|
| **Market rates** | Pursue Jobbers.io license; static seed in `rates-core` until live |
| **F13 board** | Anonymous submissions, moderated aggregates, N≥5 to display |
| **F12 earnings** | Manual entry + pipeline Paid + invoice linkage |

## Business

| Area | Decision |
|------|----------|
| **Monetization** | Free / Pro $9.99 lifetime / Pro+ $4.99/mo (requires Pro) / marketplace à la carte |
| **F14 marketplace** | Curated approval, 70/30 split, manual PayPal/Wise payouts ≥$50 |
| **Legal** | Jurisdiction picker + “not legal advice” on all documents |
| **Privacy** | GDPR-complete: export, delete, consent, processor DPAs |
| **Locales** | English + Arabic (full UI, RTL, Cairo) from day one |
| **Launch** | iOS App Store first; Android fast-follow; web fee calculator with iOS |

## Admin

Web repo `/admin` — Auth0 `admin` role; F13/F14 moderation queues, payout batch export.

## Build sequence

Foundation → wedge → documents → monetization/iOS → AI → F13 → F14 → Android.

## Rejected

- Obsidian / two-word App Store names (trademark + UX)
- MVP scope cuts
- Mobile app implementation (deferred until ticket pickup)

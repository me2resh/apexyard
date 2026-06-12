# Nomrate PRD v3

> Normalized from OBSIDIAN PRD v3.0 (June 2026). Brand renamed to **Nomrate**. Full grill decisions in `DECISIONS.md`.

## One-line positioning

**Glassdoor for freelancers meets pricing coach — with contracts built in.**

Tagline: *Know your market rate.*

## Strategic wedge

Don't build another Bonsai. Build the intelligence layer that makes freelancers realize they're undercharging. Lead with the "you're in the 23rd percentile" moment. Rate intelligence is the wedge; contracts are table stakes.

## What Nomrate is / is not

**Is:** pricing intelligence (Upwork/Fiverr/Jobbers.io data), platform fee calculator, vibe coder rate guide, lightweight contracts/proposals/invoices, mobile-first, EN+AR.

**Is not:** full invoicing SaaS, Bonsai/HoneyBook competitor, marketplace for gigs, PM tool.

## Target audience

- **Primary:** Vibe coders (Cursor, Claude Code, Bolt, Lovable, v0) — 18–35, global
- **Secondary:** Platform freelancers (Upwork, Fiverr) charging 30–50% below market

## Features (F1–F14)

See `ROADMAP.md` for build order. Feature specs and acceptance criteria are in GitHub Issues NOM-1–NOM-30 and in `NOMRATE_PRD_v3_source.docx`.

| ID | Feature | Phase |
|----|---------|-------|
| F1 | Smart rate calculator + market overlay | 1A |
| F2 | Global market rate dashboard | 1A |
| F3 | Platform fee calculator | 1A |
| F4 | Vibe coder rate guide | 1A |
| F5 | Contract generator (10 templates) | 1B |
| F6 | Proposal builder (10 templates) | 1B |
| F7 | Quick invoice | 1B |
| F8 | Client pipeline (lite) | 1B |
| F9 | Outreach & negotiation library | 1B |
| F10 | AI rate advisor | 2 |
| F11 | AI document pre-fill | 2 |
| F12 | Earnings dashboard | 2 |
| F13 | Rate transparency board | 3 |
| F14 | Template marketplace | 3 |

## Technical architecture

| Layer | Stack |
|-------|--------|
| Mobile | Expo, TypeScript, Expo Router, Zustand, MMKV, i18next |
| Web | Next.js or Vite (TBD at NOM-9), fee calc + admin |
| API | AWS CDK, Lambda, API Gateway, DynamoDB (single-table), `me-south-1` |
| Auth | Auth0 |
| AI | Claude Haiku via Lambda (Pro+) |
| Payments | RevenueCat → App Store |
| Shared | `@nomrate/rates-core` |
| PDF | HTML → `expo-print` |
| Analytics | PostHog + Sentry |

## Design system

- Accent: `#6C5CE7`
- Dark: `#0D0D1A`
- Light: `#F8F9FA`
- 5-tab nav: Home, Calculator, Docs, Pipeline, Library

## Monetization

| Tier | Price | Gates |
|------|-------|-------|
| Free | — | Basic calculator, 2 contracts, rates view, 20 hooks, 1 fee calc/day |
| Pro | $9.99 one-time | Full calculator, market overlay, all docs, library, PDF |
| Pro+ | $4.99/mo | AI features, 50 calls/day (requires Pro) |
| Marketplace | per template | 70/30 revenue share |

## GTM

Viral share cards: fee comparison + rate reveal percentile. Web fee calculator at `nomrate.app`. Channels: X/TikTok/Reddit/Product Hunt.

## Source

Original Cursor-ready ticket acceptance criteria: `NOMRATE_PRD_v3_source.docx` (OBSIDIAN PRD v3.0 export).

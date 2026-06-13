# Nourish — locked decisions

Captured via `/grill-me` (2026-06-10). Supersedes conflicting PRD open questions where noted.

## Product

| Topic | Decision |
|-------|----------|
| Scope | Full product — Layers 1 + 2 + 3, native mobile, illustrated avatar |
| Launch features | All layers fully featured day one (cycle logging, nudges, aging) |
| Geography | UK + UAE simultaneous; English + Arabic |
| Monetization | Single family subscription (~£9.99/mo or £79/yr); 14-day trial; all layers included |
| Parent model | Present / Absent roles; gender-neutral; user-chosen display names |
| Pre-birth | Expecting mode — pregnancy journal, bumper persona, Layer 3 active |
| Brand | **Nourish** (working title — trademark TBD) |
| Voice / chat | Full “Us” thread (text + voice, 3 min cap); AI never reads thread |
| Separation | Account fork; couple data + thread wiped; one free avatar regen per solo account |
| Timeline | **Gate-driven** — no fixed public launch date |

## Technical

| Topic | Decision |
|-------|----------|
| Mobile | React Native (Expo), TypeScript |
| Backend | Supabase EU (Frankfurt) + RevenueCat + Node/TS AI worker |
| Data residency | EU primary; UAE cross-border consent at onboarding |
| AI copy | Single frontier LLM; three prompt templates; native Arabic QA before launch |
| Validation | Closed beta (50) → open beta (500) → soft launch; pause if inter-parent messaging drops >15% vs week 1 |

## Avatar (spike — see AgDR-0064)

| Topic | Decision |
|-------|----------|
| Style | Illustrated storybook — not photorealistic face blend |
| Pipeline | Hybrid — initial render from parent photos; canonical PNG chains stages 2–7 |
| Stages | Bumper + 6 age stages (newborn → 18m) |
| Photo retention | Delete uploads within 24h; keep vision JSON + rendered PNGs |
| Regen | 3 free full pipeline reruns; first baby-photo upload = 1 free refresh |
| Vendors (spike) | fal.ai Flux Pro, Replicate SD3+IP-Adapter, DALL-E 3 — not Midjourney |

## PRD open questions — resolved

| PRD question | Resolution |
|--------------|------------|
| Couple layer pricing tier | Bundled in single subscription |
| Couple layer V1 minimum | Full cycle logging day one (per product grill) |
| Avatar aging cadence | Automatic on DOB milestones; parent can trigger early |
| Separation | Account fork (see above) |
| Avatar vendor | Pending SPIKE-001 → AgDR-0064 |

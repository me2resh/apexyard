# AgDR-0064: Nourish avatar vendor spike (illustrated hybrid pipeline)

**Date:** 2026-06-10  
**Status:** Proposed — **vendor selection pending SPIKE-001**  
**Deciders:** Hisham (Tech Lead), Omar (Head of Product)  
**Project:** Nourish (IDEA-002)

> In the context of Nourish’s illustrated storybook avatar (parent photos as palette reference, 7 renders per family), facing vendor policy/consistency/cost uncertainty, I decided to run a **three-vendor spike** with a **hybrid canonical-chain pipeline** and optional **split initial/aging vendors**, accepting spike labour before any mobile app scaffold.

## Context

- Nourish requires an illustrated baby/bumper avatar that ages across 6 milestones plus pre-birth bumper mode.
- Photorealistic face blend is **out of scope** (uncanny valley + policy risk).
- Parent photos are reference-conditioned on **initial render only**; stages 2–7 chain off a **stored canonical PNG** (hybrid — grill decision reversed from pure per-stage photo refs).
- EU (Frankfurt) residency; parent photos deleted within 24h post-generation.
- Spike tracked as [SPIKE-001](../../projects/nourish/SPIKE-001-avatar-vendor-api.md).

## Options considered

| Option | Pros | Cons |
|--------|------|------|
| **Midjourney** | High aesthetic quality in static trials | No production API; fails ops gates |
| **DALL-E 3 only** | Strong illustration; same vendor as LLM stack | Weak reference chaining; strict minor-adjacent policy |
| **fal.ai Flux Pro** | Reference + img2img; strong G4 candidate | Another vendor relationship |
| **Replicate SD3 + IP-Adapter** | Flexible; lower unit cost | More tuning; ops complexity |
| **Three-vendor spike (chosen)** | Evidence-based; split vendor path allowed | 2-week timebox; 420 images |

## Decision

### Pipeline (locked before spike)

1. **Vision JSON** via GPT-4o from parent photos.  
2. **Initial render** — storybook prompt + photo references → **canonical PNG**.  
3. **Stages 2–7** — img2img/reference from canonical + age deltas.  
4. **Retention** — delete photos ≤24h; keep vision JSON + PNGs.  
5. **Fallback chain** — soft prompt → vendor failover → palette preset (G6 ≥95% custom).  
6. **Regen** — locked vendors; full rerun; 3 free + 1 baby-photo refresh.

### Spike (locked)

- **Vendors:** fal.ai Flux Pro, Replicate SD3+IP-Adapter, DALL-E 3.  
- **Volume:** 20 pairs × 7 images × 3 vendors.  
- **Gates:** G1–G6; pass avg ≥4.0, min gate ≥3.  
- **Winners:** best (G1+G2+G6) → initial; best G4 → aging (may split).  
- **Timebox:** 2 weeks.

### Production vendors (fill after spike)

| Role | Vendor | Model/API | Status |
|------|--------|-----------|--------|
| Initial render | _TBD_ | _TBD_ | Pending SPIKE-001 |
| Aging chain | _TBD_ | _TBD_ | Pending SPIKE-001 |
| Vision JSON | OpenAI | GPT-4o | Locked |

## Consequences

- **No Nourish app repo** until SPIKE-001 closes and this AgDR moves to **Accepted** with vendors named.
- Production AI worker must implement fallback chain and G6 monitoring.
- Split vendors require canonical PNG in Supabase Storage as handoff contract.
- DALL-E may remain spike-only if G6 fails in production path.

## Artifacts

- [projects/nourish/DECISIONS.md](../../projects/nourish/DECISIONS.md)  
- [projects/nourish/SPIKE-001-avatar-vendor-api.md](../../projects/nourish/SPIKE-001-avatar-vendor-api.md)  
- [projects/nourish/spike/avatar-vendor/SPIKE-PLAN.md](../../projects/nourish/spike/avatar-vendor/SPIKE-PLAN.md)  

**Post-spike:** update this file — Status → Accepted; fill vendor table; link scorecard path.

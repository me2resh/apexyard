# [Spike] Nourish avatar API vendor selection

**ID:** SPIKE-001 → **GH-1** ([Dr-kersho/nourish#1](https://github.com/Dr-kersho/nourish/issues/1))  
**Project:** Nourish / IDEA-002  
**AgDR:** [AgDR-0064](../../docs/agdr/AgDR-0064-nourish-avatar-vendor-spike.md)  
**Status:** Ready to start (no app repo — spike scripts live in ops repo plan only)

## Hypothesis

We believe **one vendor (or a split pair: initial + aging) among fal.ai Flux Pro, Replicate SD3+IP-Adapter, and DALL-E 3** can produce illustrated storybook avatars that pass parent resonance and ops gates. We will know we are right when **each candidate scores ≥4.0 average across six gates with no gate below 3** on 20 diverse parent photo pairs (420 images total).

## Budget

**2 weeks** — one engineer (Tech Lead) + PM prompt work + Design storybook direction + **10-couple parent panel** for qualitative gates. Hard stop at 14 calendar days regardless of outcome.

## Kill Criteria

- **Answered yes:** A vendor (or split pair) meets all pass thresholds → record winners in AgDR-0064, disposition **PROMOTE**.
- **All vendors fail G4 (consistency)** below 3 → **stop early**, disposition **DISCARD** hybrid pipeline; re-grill architecture before any app work.
- **All vendors fail G6 (policy)** below 95% custom avatar rate → **stop early**; remove DALL-E from production path or abandon photo-reference pipeline.
- **Cost >£1.00/family** for initial + 6 stages on all vendors → **stop early**; re-scope to fewer stages or preset-heavy fallback.
- **Vendor DPA** prohibits EU processing or retains training data without opt-out → exclude vendor, do not extend spike.

## Disposition

**PROMOTE** — if hypothesis confirmed, file a `[Feature]` ticket in `Dr-kersho/nourish` (once repo exists) for production avatar worker integration. Spike code may be discarded; scorecard + sample gallery + updated AgDR are the artefacts.

**DISCARD** — if no vendor passes, write spike memo, do **not** scaffold Nourish app until architecture is re-grilled.

## Approach

See [spike/avatar-vendor/SPIKE-PLAN.md](./spike/avatar-vendor/SPIKE-PLAN.md).

**Explicitly out of scope for this spike:** mobile app, Supabase schema, RevenueCat, LLM copy layers, couple thread.

## Suggested branch (when work starts)

```
spike/GH-1-avatar-vendor-api
```

## Glossary

| Term | Definition |
|------|------------|
| Canonical render | First successful bumper/newborn PNG stored as reference for stages 2–7 |
| G1–G6 | Spike quality gates (resonance, uncanny, diversity, consistency, ops, policy) |
| Vision JSON | Structured palette/features extracted from parent photos (no raw photos retained) |
| Hybrid pipeline | Initial vendor uses photo refs; aging vendor chains img2img off canonical PNG |

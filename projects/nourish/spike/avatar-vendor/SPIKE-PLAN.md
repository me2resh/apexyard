# Avatar vendor spike — execution plan

**SPIKE-001** · **No executable code in this repo yet** · Planning artefact only

When the spike starts, implement scripts under `Dr-kersho/nourish/scripts/avatar-spike/` (future repo). Until then, this document is the spec.

## Inputs

- **20 parent photo pairs** — deliberate diversity: skin tone, hair type, lighting; signed consent forms for spike use only
- **7 prompts per pair:** bumper (pre-birth) **or** newborn (post-birth) + 6 age stages
- **3 vendors:** fal.ai Flux Pro, Replicate SD3+IP-Adapter, OpenAI DALL-E 3

## Pipeline (per vendor, per pair)

```
1. Upload parent photos → GPT-4o vision → Vision JSON (skinTone, hairColor, eyeColor, illustrationNotes, avoid[])
2. Initial render:
   - Storybook prompt + Vision JSON + parent photo references
   - Output: canonical PNG
   - On policy refusal: soft prompt → retry → (spike only) log failure
3. Stages 2–7:
   - img2img / reference input = canonical PNG
   - Age-specific prompt delta only
4. Score gates G1–G6
5. Delete source photos (simulate 24h production rule)
```

## Gates (pass: avg ≥4.0, no gate <3)

| Gate | Measurement |
|------|-------------|
| **G1 Resonance** | ≥70% of panel rate “I’d show my partner” (4+/5) |
| **G2 Uncanny** | ≤10% rate “creepy or too real” |
| **G3 Diversity** | Manual review: no stereotype drift across 10 tone/hair buckets |
| **G4 Consistency** | Embedding similarity + panel: same fictional baby across 7 stages |
| **G5 Ops** | p95 <60s; cost <£0.50/family for 7 images |
| **G6 Policy** | ≥95% pairs get custom avatar without preset fallback |

## Policy fallback (production pattern — test in spike)

1. Primary prompt + refs  
2. Sanitised prompt (fictional character tokens; avoid literal “child/baby” if refused)  
3. Vendor failover (initial render only)  
4. Palette-matched preset (counts as G6 failure)

## Winner selection

| Role | Rule |
|------|------|
| **Initial vendor** | Highest average of G1 + G2 + G6 |
| **Aging vendor** | Highest G4 (must accept canonical PNG as input) |
| **Production** | Same vendor if wins both; else split with canonical handoff via Supabase Storage URL |

## Regen (production — not spike scope)

Locked AgDR vendors; full 7-image pipeline rerun; 3 free per family; first baby-photo upload = 1 free refresh.

## Deliverables

1. `scorecard.csv` — 20 pairs × 3 vendors × 6 gates  
2. `samples/{vendor}/{pair_id}/` — 7 PNGs each  
3. Vendor DPA / no-retention notes  
4. Cost row per vendor per family  
5. Update [AgDR-0064](../../../docs/agdr/AgDR-0064-nourish-avatar-vendor-spike.md) — status **Accepted**, initial + aging vendor fields filled  

## Roles

| Role | Owner |
|------|-------|
| Spike driver | Tech Lead |
| Prompts + LoRA | PM + Design |
| Parent panel (G1/G2) | 10 couples (external) |
| Scoring G3–G6 | Eng automation + PM |
| Decision | Tech Lead + Head of Product |

## Future script layout (when `Dr-kersho/nourish` exists)

```
scripts/avatar-spike/
  README.md
  config.vendors.json
  extract-vision-json.ts
  run-vendor.ts          # fal | replicate | openai
  score-g4-similarity.ts
  generate-scorecard.ts
  fixtures/photo-pairs/  # gitignored — consent-required
  output/                # gitignored
```

**Do not create this tree until SPIKE-001 branch is opened.**

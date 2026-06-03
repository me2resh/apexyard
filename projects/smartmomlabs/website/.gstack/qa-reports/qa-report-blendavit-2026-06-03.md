# QA Report — blendavit (Smart Mom Labs)

| Field | Value |
|-------|-------|
| Date | 2026-06-03 |
| URL | http://127.0.0.1:8765/ |
| Pages | index.html, product.html |
| Tier | Standard |
| Health (baseline) | 78/100 |
| Health (after fix) | 84/100 |

## Hero background (img.hero-scene)

Two layers: (1) Unsplash lifestyle full-bleed — repo uses photo-1516627145497 (kitchen/eating); inspector may show photo-1571019613454 (playroom: chess, puzzles, Rubik's cube) until hard refresh. (2) hero-pack-stage — real pack PNG + age badge on top.

## Fixed: ISSUE-001 HIGH

PDP ?variant=toddlers now loads toddlers pack + toddlers nutrient panel (main.js syncPdpVariant).

## Deferred

- Replace Unsplash with owned GCC photography
- Self-host hero image for production
- Shopify checkout URLs in config.js
- Verify toddlers carton art matches 1-3 label

Full pass: AR/EN toggle, RTL, variant tabs, FAQ, skip link, no console errors.

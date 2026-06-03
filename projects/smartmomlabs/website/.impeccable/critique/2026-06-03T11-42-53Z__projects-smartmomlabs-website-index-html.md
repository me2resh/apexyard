---
target: blendavit homepage (index.html)
total_score: 24
p0_count: 1
p1_count: 4
p2_count: 3
timestamp: 2026-06-03T11-42-53Z
slug: projects-smartmomlabs-website-index-html
---
# blendavit homepage critique

Target: projects/smartmomlabs/website/index.html

## Heuristics (24/40 — Acceptable)

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2 | Reserve path unclear until product page; no confirmation of selected market/variant on hero |
| 2 | Match System / Real World | 3 | Parent language mostly natural; aphoristic lines ("Zero cooperation", "Zero battles") |
| 3 | User Control and Freedom | 2 | Toddlers/Kids toggle does not update hero age badge (stuck at 4+) |
| 4 | Consistency and Standards | 2 | Duplicated variant/market UI in hero + footer; emoji benefits vs serif premium pack |
| 5 | Error Prevention | 2 | Easy to reserve wrong age band without PDP review |
| 6 | Recognition Rather Than Recall | 3 | Strong FAQ; mobile hides nav anchors |
| 7 | Flexibility and Efficiency | 2 | Adequate for marketing LP |
| 8 | Aesthetic and Minimalist Design | 2 | Long page, many same-shaped sections |
| 9 | Error Recovery | 3 | FAQ explains waitlist/deposit |
| 10 | Help and Documentation | 3 | Seven FAQs cover core objections |

## Anti-Patterns

LLM: Reads as Luna & Eve structural clone (mint wash, Cormorant Garamond + DM Sans, hero grid, trust pills, stat band, 3 cards, comparison table, 3 steps, 4 icon benefits). Packaging photo is the main differentiator. Hero-metric band (89.8% / 0g) is SaaS-template energy on a parent brand page.

Detector: 14 em dashes in index.html (em-dash-overuse warning).

Browser overlays: Not injected this run (live bar present; detect overlay not run separately).

## Priority Issues

P0: reserve-note exposes "Connect Shopify + Early Bird..." to shoppers.
P1: Typography pair is reflex-reject (Cormorant Garamond + DM Sans); undermines premium GCC positioning.
P1: Identical three evidence cards (icon+quote+cite grid).
P1: Hero stat-band matches hero-metric template.
P1: No lifestyle imagery (pack-only); weak vs Luna & Eve / EllaOla parent scenes.
P2: --text-muted #707070 on #d9e9e8 likely fails body contrast.
P2: Emoji benefit icons clash with clinical SFDA story.
P2: 14 em dashes in copy.

## Personas

Jordan: Confused by duplicate Toddlers/Kids controls; developer note looks broken; "Grade A evidence" in cite may feel jargon-adjacent.

Casey: Thumb-unfriendly variant tabs in hero; long scroll to second reserve block; flag emojis in market buttons render inconsistently.

Riley: Hero badge says 4+ when Toddlers selected; Smart Mom Labs link 404; internal Shopify note visible.

## Strengths

Pack photography and mint palette match physical brand.
Iron vs gummy comparison table is clear and on-strategy.
FAQ and footer disclaimer are thorough for supplements.

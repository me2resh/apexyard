---
name: blendavit
description: SFDA-registered tasteless multivitamin for parents — KSA, Arabic-first
colors:
  bg: "#e8f2f0"
  bg-soft: "#f4faf9"
  bg-card: "#ffffff"
  text: "#1f2e26"
  text-muted: "#4a554f"
  accent: "#1a3d32"
  accent-light: "#2d5c4a"
  gold: "#8a6428"
  gold-light: "#c9a227"
  border: "rgba(26, 61, 50, 0.12)"
typography:
  display:
    fontFamily: "\"Source Serif 4\", Georgia, serif"
    fontSize: "clamp(2.4rem, 4.5vw, 3.75rem)"
    fontWeight: 600
    lineHeight: 1.08
    letterSpacing: "-0.03em"
  body:
    fontFamily: "\"Albert Sans\", system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.65
    letterSpacing: "normal"
  label:
    fontFamily: "\"Albert Sans\", system-ui, sans-serif"
    fontSize: "0.8125rem"
    fontWeight: 700
    lineHeight: 1.35
    letterSpacing: "normal"
rounded:
  sm: "12px"
  md: "18px"
  pill: "999px"
spacing:
  sm: "8px"
  md: "16px"
  lg: "24px"
  section: "64px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "15px 30px"
  button-gold:
    backgroundColor: "linear-gradient(135deg, {colors.gold-light}, {colors.gold})"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "15px 30px"
    note: "Gradient ends at gold-deep (#5c4218) for AA on reserve CTAs"
  button-secondary:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.text}"
    rounded: "{rounded.pill}"
    padding: "15px 30px"
---

## Overview

**Creative north star:** The calm pharmacy shelf, digitized — clinical trust with family warmth.

**Hero model (approved):** Lifestyle stir scene (`hero-stir-yoghurt.png`) proves “invisible in food they already eat.” Pack photography leads on **product duo cards** and **PDP**, not overlaid on the hero.

Mood: assured, readable, premium DTC supplement (EllaOla register, not UK pastel clone). Mint-tinted surfaces echo pack art; forest green and bronze gold carry action and wordmark emphasis. Layout: trust strip → bold headline → lifestyle hero → product duo → evidence → comparison → usage steps.

Anti-references for agents: generic stroke trust icons, identical icon+heading cards, hero metric bands, gradient text, glass cards, all-caps section eyebrows on every block, pack composite over lifestyle hero.

## Colors

Source of truth: `:root` tokens in `assets/css/tokens.css` (imported by `main.css`).

| Role | Token | Hex | Use |
|------|-------|-----|-----|
| Page | `bg` | `#e8f2f0` | Body + star watermark pattern |
| Section alt | `bg-soft` | `#f4faf9` | Alternating sections, hero frame |
| Surface | `bg-card` | `#ffffff` | Cards, nav bleed |
| Ink | `text` | `#1f2e26` | Headings, body |
| Muted | `text-muted` | `#4a554f` | Supporting copy (≥4.5:1 on bg) |
| Accent | `accent` | `#1a3d32` | CTAs, promo bar, step numbers |
| Accent light | `accent-light` | `#2d5c4a` | Social proof, secondary emphasis |
| CTA gold | `gold` / `gold-light` | `#8a6428` / `#c9a227` | Reserve buttons (gradient) |

Strategy: **Committed restrained** — mint field + green accent ≤15%, gold for conversion moments only.

## Typography

- **Display (LTR):** Source Serif 4 — wordmark, h1–h2, pull quotes.
- **Display (RTL):** El Messiri — Arabic headings.
- **Body (LTR):** Albert Sans — UI, body, tables, FAQ.
- **Body (RTL):** Tajawal — Arabic UI and tables (not IBM Plex; reflex-reject lane).
- **Scale:** h1 clamp max 3.75rem; body 17px / 1.65; trust labels 0.8125rem bold (0.74rem for long SFDA line).
- Use `text-wrap: balance` on headings; `pretty` on long FAQ answers.

## Elevation

- **Default shadow:** `0 20px 50px rgba(26, 61, 50, 0.12)` (`--shadow`) on product cards, step photos, hero frame.
- **Trust rail:** Hairline `border-block` only — stamps sit on the mint field, not inside a card.
- **Trust stamps:** Light `box-shadow` on `.trust-rail__stamp` (no `filter`); all stamps use double-ring circles (hex/shield shapes retired).
- No full-page glass cards; depth via white surfaces on mint field.

## Components

- **Promo bar:** Full-width `accent`, white text, gold bottom border.
- **Nav:** Sticky mint, logo serif + sans sublabel; primary CTA white on `accent`.
- **Trust rail (Direction B v3):** `<ul>` of five **unified circular** stamps at 56px, hairline dividers (desktop), label token (0.8125rem). SFDA in rail only (`trust.sfda.short`); `hero.proof` is evidence line only. `data-i18n-aria-label`. ≤640px: 2-col grid, fifth item centered. Shared on home + PDP.
- **Hero:** Copy column + `.hero-visual` lifestyle scene (4:3, `object-position: center 42%`) + age badge chrome (variant-synced, does not swap scene image).
- **Product card:** Pack shot, body stack, full-width primary button.
- **Usage steps:** Three-column grid; each step has `.step-photo` (4:3 crop, per-step `object-position`), step number chip, h3 + body.
- **Evidence row:** Serif quote mark + stagger offset on even rows (desktop).
- **Variant tabs:** 2px border; active = accent fill.
- **Compare table:** Row headers `th scope="row"`; mobile labels via `data-mobile-col` + i18n (no visually-hidden caption overflow).

### Focus (shipped)

`:focus-visible` — 2px `accent` outline, 2px offset on: lang buttons, variant tabs, market buttons, all `.btn`, FAQ summaries, logo, nav menu button. Skip link uses clip reveal on focus.

### Responsive

| Breakpoint | Trust rail | Hero |
|------------|------------|------|
| ≤900px | Still one row (flex) | Single column grid |
| ≤640px | 2-column grid, fifth credential centered | — |

## Assets (committed)

| File | Role |
|------|------|
| `assets/images/hero-stir-yoghurt.webp` | Hero lifestyle — yoghurt stir (bilingual-safe, no baked copy) |
| `assets/images/usage-stir-yoghurt.webp` | Step 4 — mix into yoghurt |
| `assets/images/campaign/pack-toddlers.png` | Product duo (Toddlers) + hub grid + PDP variant |
| `assets/images/campaign/pack-kids.png` | Product duo (Kids) + PDP default + hub hero card + OG |
| `assets/images/campaign/sachet-kids.png` | Step 2 — open sachet |
| `assets/images/campaign/science-receipt-sugar.png` | Science section — gummy 8g vs blendavit 0g receipt |
| `assets/images/campaign/science-shelf-sugar.png` | Compare section — shelf sugar comparison |
| `assets/images/campaign/nutrients-flatlay.png` | Science secondary — whole foods around sachet |
| `assets/images/campaign/sugar-jars.png` | Reserved — monthly vitamin sugar vs 0g (social / future proof2 visual) |
| `assets/icons/trust/stamp-{sugar,sfda,sachet,nutrients,halal}.svg` | Trust strip Direction B |
| `previews/trust-stamps-preview.html` | A/B/C stamp comparison board |

**Do not use on bilingual pages:** campaign shots with baked Arabic headlines (pasta pour, foods flatlay) or the zero-effort hand graphic (sachet typo). Legacy `assets/images/posters/*` and June 02 WhatsApp pack crops are superseded by `campaign/`.

Do not swap hero or step lifestyle images without explicit approval. Do not use the rejected “BLENDAVITE” jar mock or `hero-scene-kitchen.jpg` interim.

## Do's and Don'ts

**Do**

- Lead with iron-in-sachet vs gummy comparison.
- Keep SFDA + halal + 0g sugar in above-fold trust (packaging stamps).
- Use approved lifestyle + pack assets from `assets/images/`.
- Write reserve/waitlist copy for parents, not developers.
- Use “registered” / مسجّل wording for SFDA — formulation registered, not authority endorsement.

**Don't**

- Use SFDA authority logo or imply government endorsement.
- Reintroduce Cormorant Garamond + DM Sans pair.
- Revert to generic stroke/circle trust icons (Direction A).
- Use em dashes in marketing copy.
- Show Shopify setup instructions on the storefront.
- Invent paediatrician quotes without signed advisors.
- Add numbered 01/02/03 section eyebrows.
- Overlay pack shot on lifestyle hero (superseded layout).

## Open polish (pre-launch)

1. **`.btn-gold` contrast** — white text on light gold gradient fails AA; darken stops or use `#1a2e24` label text.
2. **Variant tabs** — add `aria-pressed` for active state (a11y follow-up).

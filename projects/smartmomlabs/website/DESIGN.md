---
name: blendavit
description: SFDA-registered tasteless multivitamin for parents — KSA, Arabic-first
colors:
  bg: "#e4f0ef"
  bg-soft: "#f6fbfb"
  bg-card: "#ffffff"
  text: "#3d2e1f"
  text-muted: "#5c5348"
  accent: "#2f4a38"
  accent-light: "#4a6b55"
  gold: "#9a7332"
  gold-light: "#c4a062"
  border: "rgba(61, 46, 31, 0.1)"
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
    fontSize: "0.72rem"
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: "normal"
rounded:
  sm: "10px"
  md: "16px"
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
    backgroundColor: "{colors.gold-light}"
    textColor: "#ffffff"
    rounded: "{rounded.pill}"
    padding: "15px 30px"
  button-secondary:
    backgroundColor: "{colors.bg-card}"
    textColor: "{colors.text}"
    rounded: "{rounded.pill}"
    padding: "15px 30px"
---

## Overview

**Creative north star:** The calm pharmacy shelf, digitized — clinical trust with family warmth, led by real pack photography.

Mood: assured, readable, premium DTC supplement (EllaOla register, not UK pastel clone). Mint-tinted surfaces echo pack art; forest green and bronze gold carry action and wordmark emphasis. Layout favors trust strip → bold headline → product duo cards → evidence → comparison table.

Anti-references for agents: identical icon+heading cards, hero metric bands, gradient text, glass cards, all-caps section eyebrows on every block.

## Colors

| Role | Token | Use |
|------|-------|-----|
| Page | `bg` #e4f0ef | Body wash (pack mint) |
| Section alt | `bg-soft` #f6fbfb | Alternating sections |
| Surface | `bg-card` #ffffff | Cards, panels, nav bleed |
| Ink | `text` #3d2e1f | Headings, body |
| Muted | `text-muted` #5c5348 | Supporting copy (≥4.5:1 on bg) |
| Accent | `accent` #2f4a38 | CTAs, icons, promo bar |
| CTA gold | `gold` / `gold-light` | Primary reserve buttons |

Strategy: **Committed restrained** — mint field + green accent ≤15%, gold for conversion moments only.

## Typography

- **Display (LTR):** Source Serif 4 — wordmark, h1–h2, pull quotes.
- **Display (RTL):** El Messiri — Arabic headings.
- **Body (LTR):** Albert Sans — UI, body, tables, FAQ.
- **Body (RTL):** Tajawal — Arabic UI and tables (not IBM Plex; reflex-reject lane).
- **Scale:** h1 clamp max 3.75rem; body 17px / 1.65; trust labels 0.72rem bold.
- Use `text-wrap: balance` on headings; `pretty` on long FAQ answers.

## Elevation

Single shadow vocabulary: `0 16px 48px rgba(47, 74, 56, 0.1)` on product cards, hero pack, reserve panel. No layered glass; depth via white cards on mint field.

## Components

- **Promo bar:** Full-width `accent`, white text.
- **Nav:** Sticky, blurred mint, logo serif + sans sublabel.
- **Trust strip:** 5-column icon + label grid (SVG strokes, not emoji).
- **Product card:** Image 4:3, body stack, full-width primary button.
- **Evidence row:** Serif quote mark + stagger offset on even rows (desktop).
- **Variant tabs / market buttons:** 2px border; active = accent fill or tint.
- **Compare table:** Row headers `th scope="row"` for a11y.

Focus: visible 2px accent outline on interactive elements (add in polish pass).

## Do's and Don'ts

**Do**

- Lead with iron-in-sachet vs gummy comparison.
- Keep SFDA + halal + 0g sugar in above-fold trust.
- Use pack photography from `assets/images/`.
- Write reserve/waitlist copy for parents, not developers.

**Don't**

- Reintroduce Cormorant Garamond + DM Sans pair.
- Use em dashes in marketing copy.
- Show Shopify setup instructions on the storefront.
- Invent paediatrician quotes without signed advisors.
- Add numbered 01/02/03 section eyebrows.

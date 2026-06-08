---
name: apexyard
description: SDLC-as-code ops framework — editorial mono marketing site + shadcn portfolio golden path
colors:
  paper: "#F7F3EA"
  paper-2: "#EFE9DC"
  paper-3: "#E6DFD0"
  ink: "#1A1612"
  ink-soft: "#5C5548"
  ink-faint: "#847C68"
  ink-ghost: "#B6AD9B"
  accent: "#C8321A"
  accent-soft: "#E07050"
  rule: "#1A1612"
  rule-faint: "#B6AD9B"
typography:
  display:
    fontFamily: "\"JetBrains Mono\", ui-monospace, Menlo, Consolas, monospace"
    fontSize: "clamp(1.75rem, 4vw, 2.75rem)"
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: "-0.02em"
  body:
    fontFamily: "\"JetBrains Mono\", ui-monospace, Menlo, Consolas, monospace"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: "normal"
  label:
    fontFamily: "\"JetBrains Mono\", ui-monospace, Menlo, Consolas, monospace"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.35
    letterSpacing: "0.04em"
rounded:
  sm: "4px"
  md: "8px"
spacing:
  sm: "8px"
  md: "16px"
  lg: "24px"
  section: "48px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
  button-accent:
    backgroundColor: "transparent"
    textColor: "{colors.accent}"
    rounded: "{rounded.sm}"
    padding: "8px 14px"
    note: "Accent is a stamp (links, keywords, selection) — not a primary fill"
---

## Overview

**Scope split:** `site/` (marketing) uses this editorial mono system. React/Next portfolio apps use `golden-paths/ui` (Tailwind + shadcn) — do not import site tokens into app UIs.

**North star:** A technical manuscript — warm paper, sharp ink, one vermillion accent used sparingly like a proofreader's mark.

**Mood:** Forge / terminal elegance. Dense but readable; hierarchy from weight and accent, not font switching.

## Colors

Source: `:root` in `site/index.html` (and sibling pages). Dark mode via `prefers-color-scheme: dark`.

| Role | Token | Light | Use |
|------|-------|-------|-----|
| Canvas | `paper` | `#F7F3EA` | Page background |
| Surface | `paper-2` / `paper-3` | `#EFE9DC` / `#E6DFD0` | Panels, code blocks |
| Text | `ink` | `#1A1612` | Body, headings |
| Muted | `ink-soft` / `ink-faint` | `#5C5548` / `#847C68` | Meta, secondary |
| Accent | `accent` | `#C8321A` | Links hover, keywords, selection (not large fills) |
| Rules | `rule` / `rule-faint` | `#1A1612` / `#B6AD9B` | Hairlines between sections |

Dark accent shifts to `#FF6E4A`; paper/ink invert accordingly.

## Typography

Single family: **JetBrains Mono** everywhere. Display scale via clamp; body fixed at 14px. Use weight (400 vs 600) and accent color for hierarchy — no secondary display font.

- Cap prose blocks at ~65ch where long-form appears.
- `text-wrap: balance` on hero headings.
- No all-caps body copy.

## Layout

- Max width `--max-w: 1280px`; gutter `clamp(1.25rem, 4vw, 3rem)`.
- Titlebar + terminal metaphor on homepage; interior pages share paper/ink shell.
- Hairline rules (`--rule-faint`) separate sections — not card grids.

## Motion

Minimal. Site is static HTML; respect `prefers-reduced-motion`. No decorative animation on load.

## Do

- Use accent for selection, link hover, syntax `.kw` highlights.
- Keep mono rhythm — consistent 14px body, deliberate whitespace.
- Mirror dark palette when `prefers-color-scheme: dark`.

## Don't

- Purple gradients, glassmorphism, or Inter/system-ui body on marketing pages.
- Fill large areas with accent red — stamp only.
- Import blendavit/LUMA/smartmomlabs tokens into framework or site work.
- Add a second display font without explicit brand decision.

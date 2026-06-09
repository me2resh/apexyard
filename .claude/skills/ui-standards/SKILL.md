---
name: ui-standards
description: >-
  Portfolio frontend standard — Tailwind CSS + shadcn/ui only (never MUI).
  Use on React/Next/Vite UI work. blendavit uses its own DESIGN.md only.
  LUMA uses its own isolated preset. Never mix client design systems.
disable-model-invocation: false
---

# UI standards — Tailwind + shadcn/ui

## Project firewall — read first

**blendavit and LUMA are different clients. Never mix their design systems.**

| Project | Path signal | Design source | Stack |
|---------|-------------|---------------|-------|
| **blendavit** | `projects/smartmomlabs/website/` | `DESIGN.md` (sage `#1a3d32`, Source Serif 4, Albert Sans) | Vanilla HTML + token CSS |
| **LUMA PWA** | `workspace/luma-pwa` or `projects/luma-pwa/` | `DESIGN-DIRECTION-SYSTEM-2026.md` (cherry/ivory/gold) | Next + Tailwind + shadcn + `integrations/luma-pwa/` |
| **Other React apps** | `package.json` + React | Product's own `DESIGN.md` | `golden-paths/ui/theme/` (neutral only) |

### Hard rules

- **Never** import `integrations/luma-pwa/*` into blendavit or Smart Mom Labs work
- **Never** copy blendavit tokens (sage green, SFDA parent brand) into LUMA
- **Never** reuse components, fonts, or color names across clients "for consistency"
- On blendavit: if the path contains `smartmomlabs/website`, use **only** that project's `DESIGN.md` and `assets/css/tokens.css`

## Locked stack (React apps only)

| Layer | Use | Never |
|-------|-----|-------|
| CSS | Tailwind CSS | Bootstrap, MUI styles, random CSS |
| Components | shadcn/ui | Material UI, Chakra, invented libs |
| Icons | lucide-react | Emoji icons |

## When this skill applies

```
Working on smartmomlabs/website (blendavit)?
  → STOP. This skill's React/shadcn rules do not apply.
  → Read projects/smartmomlabs/website/DESIGN.md only.

Working on luma-pwa?
  → Tailwind + shadcn + integrations/luma-pwa/ preset only.

Other React app?
  → golden-paths/ui/ neutral scaffold + that product's DESIGN.md.
```

## First 10 minutes (React only)

1. Confirm which **client/project** you are in (firewall table)
2. Read **that project's** design doc — not another client's
3. Copy `golden-paths/ui/components/ui/` primitives
4. Use `theme/globals.css` (neutral) and map product tokens into CSS variables
5. LUMA only: `integrations/luma-pwa/globals.luma.css` + `tailwind.luma.preset.ts`

## Component rules

- Primitives from `@/components/ui/` (Button, Card, Input, Label, Badge, Dialog, DropdownMenu)
- Client-specific wrappers: `components/<client>-ui/` — never shared across clients

## Anti-slop blocklist

No purple gradients, glassmorphism, `rounded-3xl` everywhere, Inter/Roboto defaults, or generic three-column feature grids.

## blendavit — separate track

- Static HTML, Arabic-first, KSA DTC
- Tokens: `assets/css/tokens.css` + `DESIGN.md`
- **Do not** add Tailwind, shadcn, or LUMA assets without explicit migration ticket
- **Do not** mention LUMA patterns when implementing blendavit pages

## LUMA — isolated track

- Files live under `golden-paths/ui/integrations/luma-pwa/` only
- Warm editorial (cherry/ivory/gold), not TD-001 brutalism
- Sync guide: `integrations/luma-pwa.md`

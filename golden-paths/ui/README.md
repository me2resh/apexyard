# UI golden path — Tailwind + shadcn/ui

Portfolio default for **React / Next.js** apps. Copy the **neutral** scaffold — never cross-pollinate client design systems.

## Project firewall (mandatory)

| Project | Client | Design source | Golden path |
|---------|--------|---------------|-------------|
| **blendavit** (Smart Mom Labs) | Smart Mom Labs | `projects/smartmomlabs/website/DESIGN.md` | **None** — vanilla HTML + token CSS only |
| **LUMA PWA** | LUMA / clinics | `projects/luma-pwa/DESIGN-DIRECTION-SYSTEM-2026.md` | `integrations/luma-pwa/` only |
| **Other React apps** | Per product | Product `DESIGN.md` | `theme/globals.css` (neutral) |

**Never** import LUMA cherry/ivory/gold into blendavit. **Never** import blendavit sage/gold into LUMA. Different clients, different brands, zero shared theme files.

## What's in the box

| Path | Purpose |
|------|---------|
| `theme/globals.css` | Neutral shadcn CSS variables (generic React apps) |
| `theme/tailwind.preset.ts` | Shared Tailwind preset (no client-specific tokens) |
| `lib/utils.ts` | `cn()` helper |
| `components/ui/*` | Seven core primitives |
| `components.json` | shadcn CLI template |
| `integrations/luma-pwa/` | **LUMA-only** theme + preset + sync guide |

## Quick start (new React app)

```bash
npx shadcn@latest init
cp golden-paths/ui/lib/utils.ts "$APP/src/lib/utils.ts"
cp golden-paths/ui/theme/globals.css "$APP/src/app/globals.css"
cp -R golden-paths/ui/components/ui "$APP/src/components/ui"
```

Map **that product's** `DESIGN.md` into CSS variables — do not copy another client's preset.

## blendavit (static site)

Follow `projects/smartmomlabs/website/DESIGN.md` only. No Tailwind, no shadcn, no LUMA files, no `golden-paths/ui/` unless an explicit framework migration ticket exists.

## Agent rule

Read `.claude/skills/ui-standards/SKILL.md` before UI work. Identify the project first; apply the correct design source from the firewall table.

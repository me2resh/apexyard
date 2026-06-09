# LUMA PWA — golden path integration (LUMA only)

**Repo:** `Dr-kersho/luma-pwa` · **Workspace:** `workspace/luma-pwa`  
**Client:** LUMA (aesthetic clinics) — **not** Smart Mom Labs / blendavit  
**Design source:** `projects/luma-pwa/DESIGN-DIRECTION-SYSTEM-2026.md` (warm editorial)

## Firewall

These files are **LUMA-only**. Never import into `projects/smartmomlabs/website/` (blendavit) or any other client project. blendavit uses `projects/smartmomlabs/website/DESIGN.md` (sage green, vanilla HTML) — a completely separate brand.

LUMA-specific assets in this folder:

- `globals.luma.css`
- `tailwind.luma.preset.ts`

Shared **neutral** primitives (`../../components/ui/`) may be copied into LUMA — but never the reverse into blendavit unless blendavit migrates to React on its own ticket.

## Goal

Align LUMA with neutral shadcn primitives while keeping LUMA tokens isolated in this integration folder.

## Do not apply

- **TD-001 brutalism** (`--radius: 0`, JetBrains Mono) — superseded by design direction 2026
- Replacing `opsUi` inline styles in one PR — phase per DESIGN-DIRECTION §5

## Adoption checklist

Run from ops repo with LUMA cloned at `workspace/luma-pwa`:

```bash
LUMA=workspace/luma-pwa
OPS=$(git rev-parse --show-toplevel)

# 1. Diff theme — merge LUMA globals toward golden path
diff -u "$LUMA/app/globals.css" "$OPS/golden-paths/ui/integrations/luma-pwa/globals.luma.css" | less

# 2. Copy missing primitives (only if LUMA lacks them)
for f in button card input label badge dialog dropdown-menu; do
  [ -f "$LUMA/components/ui/$f.tsx" ] || \
    cp "$OPS/golden-paths/ui/components/ui/$f.tsx" "$LUMA/components/ui/$f.tsx"
done

# 3. Ensure cn() helper matches
cp "$OPS/golden-paths/ui/lib/utils.ts" "$LUMA/lib/utils.ts"

# 4. Tailwind preset — add to tailwind.config.ts if not present
#    import uiPreset from '../golden-paths/ui/theme/tailwind.preset'  # or copy file locally
```

## Token mapping (LUMA → shadcn)

| LUMA token | shadcn variable | Notes |
|------------|-----------------|-------|
| `--luma-cherry` | `--primary` | CTA, active nav |
| `--luma-gold` | `--accent` | Verified, proof |
| `--luma-ivory` | `--background` | Patient surfaces |
| `--luma-card` | `--card` | Card fill |
| `--luma-border` | `--border` | 1px borders, no drop shadow on patient |
| `--radius-card` (12px) | `--radius` | `rounded-card` |
| `--radius-ui` (10px) | `rounded-ui` | Workbench controls |

Keep `--luma-*` aliases in CSS for pages still referencing legacy vars.

## Phase plan (from design direction)

| Phase | Work | Golden path touchpoint |
|-------|------|------------------------|
| **A** | Extract `opsUi` → `@/components/luma-ui` | Extend `components/ui/` or add `components/luma-ui/` |
| **B** | Explore + clinic cards | Use `Card`, `Badge`, `Button` only |
| **C** | Book wizard chrome | `Dialog`, step footer with `Button` |
| **D** | Admin KPI simplification | `Card` + table patterns |

## PR convention

Branch: `refactor/LUM-NNN-golden-path-ui-sync`  
Title: `refactor(LUM-NNN): sync theme with golden-paths/ui`

## Verify

```bash
cd workspace/luma-pwa
npm run lint && npm run build
```

Open patient explore + clinic admin — cherry active states, ivory surfaces, 12px cards unchanged visually.

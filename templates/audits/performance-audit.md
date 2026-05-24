<!-- Source: ApexYard · templates/audits/performance-audit.md · github.com/me2resh/apexyard · MIT -->

# Performance Audit — {project} @ {short-sha}

> Persisted by `/performance-audit` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

What's measurable from the codebase without running Lighthouse: bundle size, image optimisation, lazy loading, code splitting, caching headers, database query patterns. Out of scope: actual Core Web Vitals from real-user monitoring (that's a `/launch-check` job once instrumented).

## Findings

| # | Area | Status | Detail | Severity |
|---|---|---|---|---|
| P1 | JS bundle size (gzipped) | FAIL | Initial bundle 380 KB; budget is 250 KB. Largest contributors: lodash (full import, 70 KB), moment (62 KB), three full chart libraries. | high |
| P2 | Images optimised | WARN | 12 images shipped as PNG; 8 are >100 KB and could be WebP/AVIF | medium |
| P3 | Below-the-fold lazy loading | WARN | `loading="lazy"` missing on 14 hero/below-fold `<img>` | medium |
| P4 | Code splitting | PASS | Next.js dynamic imports used for the 4 admin routes | — |
| P5 | Cache-Control headers | FAIL | Static assets served with `no-cache`; misses CDN edge caching | high |
| P6 | Database N+1 patterns | WARN | `getOrderHistory` loops `await order.user` per iteration; should join | medium |

## Recommended priority

1. P1 — replace `import _ from 'lodash'` with per-function imports; replace moment with date-fns; tree-shake chart libs
2. P5 — fix Cache-Control on the static-asset middleware
3. P2 — image conversion (one-shot script + CDN auto-format)
4. P3 — sprinkle `loading="lazy"` (10 min)
5. P6 — eager-load with `include` (Prisma) / `populate` (TypeORM)

## Notes

(Context: target devices, prior Lighthouse scores, traffic patterns informing bundle/image priorities.)

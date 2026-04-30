---
name: performance-audit
description: Performance analysis — bundle size, image optimization, lazy loading, code splitting, caching, Core Web Vitals readiness. Deep-dive companion to /launch-check's performance dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: medium
---

# /performance-audit — Bundle & Core Web Vitals Analysis

Deep-dive performance analysis focused on what's measurable from the codebase without running Lighthouse. Checks bundle size, image optimization, lazy loading, code splitting, and caching configuration. Invoke when `/launch-check`'s performance row shows WARN or FAIL.

## Process

### Step 1: Bundle analysis

- Check for build output (`dist/`, `build/`, `.next/`, `out/`)
- If build exists: measure total JS + CSS size, identify the 5 largest files
- Check for code splitting (dynamic imports, `React.lazy`, `next/dynamic`, route-based splitting)
- Check for tree shaking configuration (ES modules, `sideEffects: false` in package.json)
- Check if source maps are excluded from production build

### Step 2: Image optimization

- Find all images in the project (src, public, static, assets directories)
- Check formats: are images served as WebP/AVIF, or only PNG/JPEG?
- Check for oversized images (> 500KB, > 2000px width)
- Check for `next/image`, `@astrojs/image`, or similar optimization components
- Check for `loading="lazy"` on below-the-fold images
- Check for explicit `width` and `height` attributes (prevents layout shift)

### Step 3: Loading performance

- Check for render-blocking resources (CSS in `<head>` without `media`, sync `<script>` without `defer`/`async`)
- Check for font loading strategy (`font-display: swap`, preloading, self-hosted vs Google Fonts)
- Check for preconnect/prefetch hints for critical third-party origins
- Check for service worker or caching configuration

### Step 4: API performance (if applicable)

- Check for N+1 query patterns (multiple sequential fetches that could be batched)
- Check for pagination on list endpoints
- Check for caching headers (Cache-Control, ETag)
- Check for compression middleware (gzip/brotli)

### Step 5: Output

```
PERFORMANCE AUDIT — <project> @ <sha>

| # | Area | Status | Finding |
|----|------|--------|---------|
| P1 | Bundle | WARN | Total JS 420KB gzipped (target: < 300KB). Largest: vendor.js 180KB |
| P2 | Code splitting | PASS | 12 dynamic imports, route-based splitting configured |
| P3 | Images | FAIL | 8 images > 500KB, none in WebP format |
| P4 | Lazy loading | WARN | 4 below-fold images without loading="lazy" |
| P5 | Fonts | PASS | Self-hosted, font-display: swap |
| P6 | Caching | PASS | Cache-Control headers on static assets |

Performance readiness: NEEDS WORK (1 fail, 2 warnings)
Estimated LCP improvement: -1.2s if images are optimized and lazy-loaded
```

## Rules

1. **Auto-PASS for non-web projects.** APIs, CLIs, libraries measure performance differently.
2. **Measure what you can from code.** This skill reads source files and build output — it doesn't run Lighthouse. Suggest running Lighthouse separately for runtime metrics.
3. **Give specific file names and sizes** for the largest offenders, not just "bundle is too big."
4. **Estimate impact** where possible ("optimizing these 3 images would save ~800KB and improve LCP by ~1s").

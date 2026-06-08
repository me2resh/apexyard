# PERFORMANCE AUDIT — blendavit website @ dcb386f+

| # | Area | Status | Finding |
|---|------|--------|---------|
| P1 | Bundle | PASS | Static site — ~45KB CSS + ~35KB JS total (unminified); no build step |
| P2 | Code splitting | N/A | No JS bundler; scripts loaded with `defer` in document order |
| P3 | Images | WARN → FIX | 5 PNG assets >500KB on disk; below-fold steps/science now prefer WebP in markup |
| P4 | Lazy loading | PASS | Below-fold images use `loading="lazy"`; hero uses `fetchpriority="high"` + preload |
| P5 | Fonts | PASS | Google Fonts with `display=swap`; PDP drops unused Source Serif |
| P6 | Caching | PASS | Vercel static asset caching; no service worker (acceptable for MVP) |
| P7 | Render blocking | PASS | Scripts at end of body with `defer`; CSS single file |
| P8 | GEO | FIX | Added `llms.txt` + hub in sitemap |

**Performance readiness:** GOOD (warnings addressed in Phase 5)

**Estimated savings:** ~2.1MB fewer bytes on initial science + steps path when WebP is served (vs PNG fallbacks for legacy browsers only).

**Follow-up:** Wire OG image to WebP when social crawlers accept it. Removed unused `hero-stir-01.png` / `hero-stir-02.png` (~1MB deploy savings).

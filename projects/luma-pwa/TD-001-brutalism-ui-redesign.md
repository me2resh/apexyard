# Technical Design: ApexYard Brutalism UI Redesign

**Status**: Draft
**Author**: Tech Lead / Frontend Engineer
**Date**: 2026-05-05
**PRD**: [PRD-001](PRD-001-brutalism-ui-redesign.md)

---

## Overview

### Summary

Replace the LUMA PWA visual design system from the current luxury aesthetic (5 typefaces, gold palette, rounded corners) to the ApexYard terminal-native brutalism system (JetBrains Mono mono font, warm paper palette `#F4EFE6`, red accent `#C8321A`, sharp zero-radius corners). The change is CSS-only — no component hierarchy, business logic, or data flow is affected.

### Goals

- Single font family (JetBrains Mono) across 100% of pages
- Consistent brutalism palette via CSS custom properties with legacy aliases
- Zero border-radius globally
- Dark mode via `prefers-color-scheme`
- Backward compatibility for all existing inline styles referencing `--luma-*` vars

### Non-Goals

- No changes to page layout, component structure, or DOM hierarchy
- No changes to business logic, auth flows, or data fetching
- Admin panel retains legacy aliases but is not proactively redesigned
- No JavaScript-based theme toggle (media query only)

---

## Architecture

### Component / File Map

```
Layout Layer:
  globals.css          ← all CSS custom properties, base styles, utilities
  tailwind.config.ts   ← fontFamily, colors, borderRadius, animations

App Pages (updated):
  app/layout.tsx            ← JetBrains Mono <link>, removed 5 font imports
  app/page.tsx              ← terminal-style hero, sharp inputs
  app/clinic/[id]/page.tsx  ← titlebar with dots, brutal cards

Shared Components (updated):
  components/BottomNav.tsx    ← monospace uppercase labels, new palette
  components/CookieBanner.tsx ← sharp borders, brutal buttons
  components/ErrorBoundary.tsx ← new palette, monospace button

Other pages (existing):
  All other pages           ← render via legacy --luma-* aliases
```

### CSS Cascade Strategy

```
1. globals.css :root   →  new brutalism custom properties
2. globals.css :root   →  legacy aliases (--luma-black, --luma-gold, etc.
                           resolve to new values)
3. tailwind.config.ts  →  luma-* color tokens + single mono fontFamily

Any page using var(--luma-*) or tailwind luma-* classes inherits new values.
Any page with hardcoded colors is unaffected (no breaking changes).
```

### Dark Mode

```css
@media (prefers-color-scheme: dark) {
  :root {
    --paper:    #15120D;
    --paper-2:  #1C1813;
    --paper-3:  #25201A;
    --ink:       #F2EBD9;
    --ink-soft:  #C5BEAA;
    --ink-faint: #847C68;
    --ink-ghost: #4A4338;
    --accent:      #FF6E4A;
    --accent-soft: #FFA180;
    --rule:        #F2EBD9;
    --rule-faint:  #4A4338;
  }
}
```

---

## Implementation Plan

### Tasks

| # | Task | Estimate | Dependencies |
|---|------|----------|--------------|
| 1 | Update `globals.css`: brutalism palette, legacy aliases, base resets | 30m | — |
| 2 | Update `tailwind.config.ts`: single font, new tokens, radius 0 | 15m | — |
| 3 | Update `app/layout.tsx`: replace 5 font imports with JetBrains Mono `<link>` | 15m | — |
| 4 | Redesign `app/page.tsx` (login): terminal hero, sharp inputs, accent divider | 30m | 1 |
| 5 | Redesign `app/clinic/[id]/page.tsx`: titlebar with dots, brutal cards, tag pills | 45m | 1 |
| 6 | Update `components/BottomNav.tsx`: monospace, uppercase, new palette | 15m | 1 |
| 7 | Update `components/CookieBanner.tsx`: brutal style, sharp buttons | 15m | 1 |
| 8 | Update `components/ErrorBoundary.tsx`: new palette, monospace button | 10m | 1 |
| 9 | Verify build compiles | 5m | 1–8 |
| 10 | Visual audit across all routes | 30m | 1–9 |

**Total Estimate**: ~4 hours

---

## Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| JetBrains Mono Google Fonts fetch fails at build time | High (network restricted env) | Low | Use `<link>` tag instead of `next/font/google` — font loads at runtime only |
| Existing inline styles hardcode old `--luma-*` values | Certain | Low | Legacy aliases in `:root` map old names to new values automatically |
| Dark mode breaks on custom elements | Low | Low | Only `prefers-color-scheme` used — no JS toggle to break |
| Third-party components (shadcn/ui) have hardcoded radii | Medium | Low | `--radius: 0` CSS variable overrides shadcn defaults |

---

## Testing Strategy

| Type | Coverage | Notes |
|------|----------|-------|
| Visual audit | All 14 routes | Manual check: fonts, colors, spacing, corners, dark mode |
| Build | Compilation | `next build` must compile with zero errors |
| Lighthouse | Key pages | FCP, CLS comparison before/after |

### QA Checklist (per route)

- [ ] Body font is JetBrains Mono
- [ ] Background is correct paper tone
- [ ] All corners are sharp (0px radius)
- [ ] Dark mode inverts correctly
- [ ] No layout shift compared to before

---

## Open Questions

| Question | Owner | Status |
|----------|-------|--------|
| Should admin panel pages receive full brutalism treatment in this ticket or follow-up? | Dev | Open — currently resolved by legacy aliases |
| Verify DHA compliance page unaffected (Arabic font fallback removed) | Dev | Open — Noto Naskh Arabic was the Arabic font; JetBrains Mono has no Arabic glyphs |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Tech Lead | Dev | 2026-05-05 | Author |
| Head of Engineering | Dev | — | Pending |

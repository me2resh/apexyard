# PRD: ApexYard Brutalism UI Redesign

**Status**: Draft
**Author**: Head of Product
**Created**: 2026-05-05
**Last Updated**: 2026-05-05

---

## Overview

### Problem Statement

The LUMA PWA currently uses 5 different typefaces (Playfair Display, EB Garamond, Inter, Space Grotesk, Noto Naskh Arabic) with a luxury gold/champagne aesthetic. This creates visual inconsistency, increases CSS bundle size, and diverges from the ApexYard forge design system used across all managed projects. Users experience a fragmented visual identity across pages.

### Target User

**Primary**: End-users browsing clinics, booking appointments, and managing their profile on LUMA

### Goals

1. Establish a single, consistent visual identity across all pages using the ApexYard terminal-native brutalism design system
2. Reduce font loading from 5 typefaces to 1 (JetBrains Mono), improving page load performance
3. Align LUMA's UI with the ApexYard forge design language shared across all managed projects

### Non-Goals (Out of Scope)

- Changing page layout/structure or component hierarchy
- Modifying business logic or data flow
- Adding new pages or features
- Redesigning the admin panel beyond font/color token updates

### Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| Font requests reduced | 5→1 font family | Network tab / bundle analysis |
| Lighthouse perf improvement | +5 points on FCP | Lighthouse CI |
| Visual consistency | 0 font-family overrides across pages | Codebase audit |

---

## User Stories

### US-1: Consistent visual identity
>
> As a user, I want the app to look visually cohesive across all pages, so that the experience feels polished and intentional.

**Acceptance Criteria**:

- [ ] Every page uses the same font family (JetBrains Mono) for all text
- [ ] Color palette is consistent (warm paper `#F4EFE6`, dark ink `#1A1612`, red accent `#C8321A`)
- [ ] All corners are sharp (border-radius: 0) across cards, buttons, inputs
- [ ] Dark mode supported via `prefers-color-scheme`

---

### US-2: Terminal-native navigation
>
> As a user, I want navigation elements to use the terminal titlebar pattern, so the UI feels cohesive with the brutalism design language.

**Acceptance Criteria**:

- [ ] Top sticky bars use the terminal-style dot pattern (● ● ● with red warn dot)
- [ ] Bottom navigation uses monospace labels with uppercase letter-spacing
- [ ] Buttons are flat (no gradient/shadow) with sharp borders and hover inversion

---

### US-3: Backward compatibility for existing code
>
> As a developer, I want existing pages to render correctly without manual updates, so the redesign doesn't block other work.

**Acceptance Criteria**:

- [ ] All legacy CSS variable names (`--luma-black`, `--luma-gold`, `--font-display`, etc.) resolve to the new values
- [ ] Legacy utility classes (`luxury-card`, `luxury-btn`) have equivalent `brutal-*` replacements
- [ ] Tailwind config provides `luma-*` color tokens mapping to the new palette

---

### Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| User prefers reduced motion | All animations and transitions disabled |
| Dark mode OS setting | Palette inverts to dark paper (#15120D) + light ink (#F2EBD9) |
| Third-party components with inline styles | Unaffected; global CSS variables provide the palette |
| JetBrains Mono fails to load | Falls back to `ui-monospace, SF Mono, Menlo, Consolas, monospace` |

---

## Requirements

### Functional Requirements

| ID | Requirement | Priority | Notes |
|----|-------------|----------|-------|
| FR-1 | Replace all Google Font imports with JetBrains Mono | Must | |
| FR-2 | Update CSS custom properties to brutalism palette | Must | Include legacy aliases |
| FR-3 | Replace all border-radius: 12px with 0 | Must | |
| FR-4 | Update login page to match terminal hero style | Must | |
| FR-5 | Update clinic detail page with terminal titlebar + brutal cards | Must | |
| FR-6 | Update BottomNav to monospace labels, new colors | Must | |
| FR-7 | Update CookieBanner to brutalist style | Must | |
| FR-8 | Update ErrorBoundary to brutalist style | Must | |
| FR-9 | Add `brutal-card`, `brutal-btn`, `brutal-tag`, `brutal-divider` utility classes | Must | |
| FR-10 | Update tailwind.config.ts with single font + new colors | Must | |
| FR-11 | Add dark mode support via `prefers-color-scheme` | Should | |
| FR-12 | Add `rise` animation for page-load reveal | Should | |

**Priority Key**: Must (required for launch) | Should (important) | Could (nice to have)

### Non-Functional Requirements

| Category | Requirement | Target |
|----------|-------------|--------|
| Performance | Font load requests reduced from 5 to 1 | 1 HTTP request |
| Accessibility | Color contrast ratios maintained | WCAG AA minimum |
| Compatibility | Legacy CSS variables preserved as aliases | 100% of existing pages render unchanged |

---

## Design

### User Flow

```
[User loads any page]
    |
    v
[Global CSS applies: JetBrains Mono, paper bg, sharp corners]
    |
    v
[Terminal-style titlebar with dot pattern]
    |
    +---> [Page-specific content in brutalist cards]
    |
    +---> [Bottom nav: monospace, uppercase labels]
    |
    +---> [Footer/CTA: flat buttons with hover inversion]
```

### Design Reference

The design system mirrors the ApexYard landing page at `https://github.com/me2resh/apexyard` (`site/index.html`):

- **Typeface**: JetBrains Mono (100–800 weight)
- **Paper**: `#F4EFE6` light / `#15120D` dark
- **Ink**: `#1A1612` light / `#F2EBD9` dark
- **Accent**: `#C8321A` light / `#FF6E4A` dark
- **Corners**: sharp (0px)
- **Borders**: 1px solid ink
- **Hover**: background/color inversion on buttons

---

## Technical Notes

### Dependencies

| Dependency | Type | Status | Owner |
|------------|------|--------|-------|
| JetBrains Mono (Google Fonts) | External | Ready | — |
| Tailwind CSS | Internal | Ready | — |
| CSS Custom Properties | Internal | Ready | — |

### Technical Constraints

- Must use CSS `@import` or `<link>` for JetBrains Mono (not `next/font/google` due to build-time fetch restrictions in the current network environment)
- Legacy CSS variables must map to new values, not be renamed, to avoid touching every inline `style={{}}` usage across 30+ pages
- Dark mode must use `prefers-color-scheme` media query (no JS toggle)

---

## Launch Plan

### Rollout Strategy

- [x] All users at once (CSS-only change, no feature flag needed)
- [ ] Phased rollout
- [ ] Beta program first

---

## Open Questions

| Question | Owner | Status | Resolution |
|----------|-------|--------|------------|
| Should admin panel also use brutalism or remain separate? | Dev | Open | Currently using legacy aliases — revisit in follow-up |
| Verify dark mode contrast for gold/pricing elements | Dev | Open | |

---

## Timeline

| Milestone | Target Date | Status |
|-----------|-------------|--------|
| PRD Approved | 2026-05-05 | Draft |
| Ticket Created | 2026-05-05 | Done (#36) |
| Design Complete | 2026-05-05 | Done |
| Dev Complete | 2026-05-05 | Done |
| QA Complete | 2026-05-06 | Pending |
| Launch | 2026-05-06 | Pending |

---

## Approvals

| Role | Name | Date | Status |
|------|------|------|--------|
| Product Manager | Dev | 2026-05-05 | Author |
| Head of Product | Dev | — | Review |
| Tech Lead | Dev | — | Review |
| Head of Design | Dev | — | Review |

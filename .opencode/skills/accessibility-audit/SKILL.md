---
name: accessibility-audit
description: Comprehensive WCAG 2.1 AA accessibility audit — checks perceivable, operable, understandable, and robust criteria across the codebase. Deep-dive companion to /launch-check's accessibility dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: high
---

# /accessibility-audit — WCAG 2.1 AA Compliance

Deep-dive accessibility analysis against the Web Content Accessibility Guidelines 2.1 Level AA. Produces a prioritized findings list with fix instructions. Invoke when `/launch-check`'s accessibility row shows WARN or FAIL, or proactively for any user-facing app.

## WCAG Principles (POUR)

| Principle | What it means | Key checks |
|-----------|--------------|------------|
| **P**erceivable | Content must be presentable in ways users can perceive | Alt text, captions, color contrast, text resizing |
| **O**perable | Interface must be navigable and usable | Keyboard access, focus management, skip links, timing |
| **U**nderstandable | Content and UI must be understandable | Language declaration, consistent navigation, error identification |
| **R**obust | Content must work across assistive technologies | Valid HTML, ARIA usage, semantic elements |

## Process

### Step 1: Scan for structural issues

Grep the codebase for common accessibility failures:

- `<img` without `alt` attribute
- `<input` without associated `<label>` or `aria-label`
- `onClick` without `onKeyDown` / `onKeyPress` (keyboard inaccessible)
- `<div>` or `<span>` used as buttons without `role="button"` and `tabIndex`
- Missing `<html lang="...">` attribute
- Heading hierarchy gaps (h1 → h3 with no h2)
- Missing `<main>`, `<nav>`, `<header>`, `<footer>` landmarks
- Color values with insufficient contrast ratios (check theme files / CSS variables)
- Missing skip-to-content link
- Auto-playing media without controls
- Forms without error identification (`aria-invalid`, `aria-describedby`)

### Step 2: Check ARIA usage

- `aria-label` on interactive elements without visible text
- `aria-hidden="true"` not applied to decorative elements
- `role` attributes used correctly (not `role="button"` on a `<div>` that should be a `<button>`)
- Live regions (`aria-live`) for dynamic content updates
- `aria-expanded` / `aria-controls` on expandable sections

### Step 3: Output findings

```
ACCESSIBILITY AUDIT — <project> @ <sha>

| # | WCAG | Criterion | Severity | Finding | Fix |
|----|------|-----------|----------|---------|-----|
| A1 | 1.1.1 | Non-text content | HIGH | 12 images missing alt text | Add descriptive alt attributes |
| A2 | 2.1.1 | Keyboard | HIGH | 3 onClick handlers without keyboard equivalent | Add onKeyDown with Enter/Space handling |
| A3 | 1.4.3 | Contrast | MEDIUM | Button text #999 on #fff = 2.8:1 (needs 4.5:1) | Darken to #767676 or darker |
| A4 | 2.4.1 | Skip nav | LOW | No skip-to-content link | Add <a href="#main" class="skip-link"> |

Summary: <N> findings (<N> high, <N> medium, <N> low)
WCAG 2.1 AA estimate: <PASS / PARTIAL / FAIL>
```

## Rules

1. **Cite WCAG criteria numbers** (e.g. 1.1.1, 2.1.1) so findings are traceable to the spec.
2. **Prioritize by user impact**, not by WCAG level. A missing alt on a hero image is worse than a missing skip link.
3. **Auto-PASS for non-UI projects.** CLIs, APIs, and libraries don't need this audit.
4. **Give copy-pasteable fixes** where possible (the exact HTML/JSX to add, not just "fix the contrast").

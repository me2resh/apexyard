<!-- Source: ApexYard · templates/audits/accessibility-audit.md · github.com/me2resh/apexyard · MIT -->

# Accessibility Audit — {project} @ {short-sha}

> Persisted by `/accessibility-audit` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

WCAG 2.1 Level AA. Out of scope: AAA criteria (these are aspirational), bespoke screen-reader UX testing (requires a real user, not a static read).

## Findings by POUR principle

### Perceivable

| # | Criterion | Status | Detail | Severity |
|---|---|---|---|---|
| A1 | Image alt text (1.1.1) | FAIL | 8 `<img>` tags without `alt`; banner image, product hero, etc. | high |
| A2 | Colour contrast (1.4.3) | WARN | 3 button states fail 4.5:1 (CTA disabled, footer link hover, form placeholder) | medium |

### Operable

| # | Criterion | Status | Detail | Severity |
|---|---|---|---|---|
| A3 | Keyboard nav (2.1.1) | PASS | Tab order verified on all primary flows | — |
| A4 | Focus visible (2.4.7) | FAIL | Custom buttons override default focus ring; no replacement | high |

### Understandable

| # | Criterion | Status | Detail | Severity |
|---|---|---|---|---|
| A5 | Form labels (3.3.2) | WARN | 2 inputs use placeholder-as-label only | medium |
| A6 | Error identification (3.3.1) | PASS | Error messages tied to fields via `aria-describedby` | — |

### Robust

| # | Criterion | Status | Detail | Severity |
|---|---|---|---|---|
| A7 | Valid markup (4.1.1) | PASS | No duplicate IDs detected | — |
| A8 | Name/role/value (4.1.2) | WARN | Custom dropdown lacks `role="combobox"` | medium |

## Recommended priority

1. A1 — alt text (cheap fix, big impact for screen-reader users)
2. A4 — focus ring (keyboard users can't see where they are)
3. A2 — contrast (WCAG-AA blocker for low-vision users)
4. A5, A8 — form / ARIA polish (next sprint)

## Notes

(Context: target audience, prior axe/wave scan results, manual screen-reader testing results.)

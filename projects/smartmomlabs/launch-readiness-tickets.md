# blendavit launch-readiness tickets

**Filed:** 2026-06-07 · **Tracker:** [me2resh/apexyard](https://github.com/me2resh/apexyard)  
**Parent:** [#556 — pre-launch commerce UX](https://github.com/me2resh/apexyard/issues/556)  
**Trigger:** Launch-check conditional-go + QA report 2026-06-04

## Ticket DAG

```
#571 Privacy/terms ──┬──> #572 Cookie consent ──> #573 Analytics
                     │
#575 SEO/OG ─────────┘ (parallel)

#570 Email backend (operator: form URL)

#574 Sentry (operator: DSN)

#576 llms.txt (P2, optional)
```

## Tickets

| # | Title | Priority | Blocks launch? |
|---|-------|----------|----------------|
| [#570](https://github.com/me2resh/apexyard/issues/570) | Wire email capture to waitlist backend | P1 | Yes — emails go nowhere today |
| [#571](https://github.com/me2resh/apexyard/issues/571) | Privacy policy + terms (AR/EN) | P1 | Yes |
| [#572](https://github.com/me2resh/apexyard/issues/572) | Cookie/localStorage consent banner | P1 | Yes |
| [#573](https://github.com/me2resh/apexyard/issues/573) | Analytics commerce funnel events | P1 | Yes (measurement) |
| [#574](https://github.com/me2resh/apexyard/issues/574) | Sentry browser monitoring | P1 | Yes (ops) |
| [#575](https://github.com/me2resh/apexyard/issues/575) | robots.txt, sitemap, OG meta | P1 | Warn only |
| [#576](https://github.com/me2resh/apexyard/issues/576) | llms.txt GEO artefacts | P2 | No |

## Operator inputs (before engineering can close)

1. **Formspree form ID** or **Klaviyo list endpoint** → unblocks #570
2. **Plausible domain** or **GA4 measurement ID** → unblocks #573
3. **Sentry DSN** + alert email → unblocks #574
4. **Legal copy sign-off** on privacy/terms (KSA waitlist, deposit disclosure) → unblocks #571

## In progress (local)

| Ticket | Status |
|--------|--------|
| #575 SEO | Implemented locally — `robots.txt`, `sitemap.xml`, OG/canonical on index + PDP |
| #571 Legal | Implemented locally — DRAFT `privacy.html` + `terms.html`, footer + form links |
| #572 Consent | Implemented locally — `consent.js` banner, gates cart/discount storage |

## Re-run after merge

`/launch-check projects/smartmomlabs/website` — target verdict: **GO with warnings** (mutation testing N/A for static site).

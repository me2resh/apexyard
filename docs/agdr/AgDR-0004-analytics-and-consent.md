---
id: AgDR-0004
timestamp: 2026-04-19T08:30:00Z
agent: atlas
model: claude-opus-4-7
trigger: retrospective
status: executed
ticket: me2resh/apexyard#92
---

# Google Analytics + self-rolled consent banner for the landing page

> In the context of needing traffic measurement on the ApexYard landing page now that it publishes at `yard.apexscript.com`, facing the choice between Google Analytics with a self-rolled consent banner, Google Analytics with a third-party CMP, a privacy-first analytics service (Plausible / Umami), or no analytics at all, I decided to ship **GA4 with Consent Mode v2 and a minimal self-rolled accept/decline banner**, accepting that the banner doesn't offer per-category granularity and that we'll owe a proper CMP the moment the site's analytics needs grow past "count visits".

## Context

The ApexYard landing page is a single static HTML file published to `yard.apexscript.com` via Netlify. The CEO wanted a quick way to see how much traffic the site gets — nothing sophisticated, just "is this actually getting viewed". The repo is open-source, experimental, and not monetised; there is no marketing team, no growth funnel, no retargeting.

The site is served to visitors in the EU and UK, which means GDPR and ePrivacy apply. Analytics cookies / local storage / identifiers require explicit consent BEFORE they are set. Any analytics choice has to account for this.

Two constraints shaped the decision:

1. **The CEO already provided the GA4 tag** (`G-G3EMR3CB02`) — there was an explicit preference for Google Analytics, not an open "which tool" question.
2. **The decision was made inline during PR #91** and shipped without an AgDR — this record is a retrospective backfill. Rex's post-review flagged the missing AgDR as a non-blocking suggestion, logged as part of #92.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **GA4 + self-rolled banner (chosen)** | Minimal code (~35 lines CSS, ~20 lines JS); matches the site's brutalist monochrome aesthetic; Consent Mode v2 means gtag loads but sends nothing until explicit grant; IP anonymization on; `ay-consent` key in localStorage persists choice. | No per-category controls (only a single analytics_storage toggle); no Do-Not-Track integration; no preference-centre UI; the banner JS and markup are maintenance surface we own. |
| **GA4 + third-party CMP** (Cookiebot, OneTrust, Osano, Iubenda, etc.) | Legal-grade compliance; per-category granularity; audit logs; cookie auto-scan; preference centre out of the box. | Adds a vendor dependency, per-month cost (free tiers usually cap at 50k pageviews and feel spammy); extra script weight on a ~100KB static page; visually inconsistent with the brutalist design without heavy theming; overkill for "count visits on an OSS landing page". |
| **Plausible / Umami / Fathom** (cookieless analytics) | No banner required at all (no cookies, no personal identifiers); lighter script; privacy-first narrative fits an OSS tool. | CEO's existing asset was a GA4 tag, not a Plausible account; self-hosting Umami means running a DB we don't have; Plausible SaaS is ~$9/mo (small but real); GA4's deeper ecosystem (Search Console link, BigQuery export) is unused today but available if needs grow. |
| **No analytics** | Zero compliance surface. Simplest possible answer. | CEO explicitly asked for traffic measurement. |

## Decision

Chosen: **GA4 with Consent Mode v2 + self-rolled banner**, because the site's current analytics need is genuinely "count visits, nothing else", the CEO has a GA tag already, and a third-party CMP would be heavier than the analytics it gates. Consent Mode v2 specifically (rather than the older "don't load gtag until consent" pattern) because it keeps the code in one place — gtag always loads with `default: denied`, and the banner only flips a single `consent: update` call.

Key configuration choices:

- Default state for all four Consent Mode v2 categories (`ad_storage`, `ad_user_data`, `ad_personalization`, `analytics_storage`) = `denied`. Only `analytics_storage` is ever requested via `update`.
- `anonymize_ip: true` on `gtag('config', ...)`.
- Choice persisted in `localStorage['ay-consent']` as `granted` or `denied`; banner auto-hides on subsequent visits until cleared.
- Banner uses `role="dialog"` + `aria-label` — **flagged for correction in #92** as `role="region"` is the better a11y fit for a non-modal banner (planned, separate commit on the same branch).

## Consequences

Positive:

- Traffic is now measurable in GA4, gated by consent, starting the day DNS flips to `yard.apexscript.com`.
- No recurring vendor cost, no extra script dependency, ~55 lines of code total.
- The "we practise what we preach" posture — the landing page for an SDLC framework respects GDPR out of the box.

Negative (accepted):

- If analytics needs grow (marketing attribution, A/B testing, conversion funnels), the self-rolled banner is not sufficient. A proper CMP becomes the right answer and a migration is ours to run.
- Per-category preferences are not offered — users choose analytics-on or analytics-off, with no "essential cookies only + no analytics" middle ground (which happens to match reality for this site since there are no other cookies, but is not explicit).
- The banner is maintenance surface. A future dependency upgrade or CSS refactor could break it silently if we don't have a smoke test.

Trigger-points for revisiting this decision:

- The landing page starts selling anything (move to a full CMP).
- We add a second analytics pixel (Segment, Hotjar, etc.) — a CMP becomes cheaper than self-rolling per-category toggles.
- GA4 is retired or its licence changes — migrate to a cookieless alternative in one shot rather than chaining providers.
- UK / EU enforcement tightens meaningfully on self-rolled banners.

## Artifacts

- Shipped in PR #91 (merge commit `6cbc95b`)
- Banner markup + JS: `site/index.html` (bottom of body + style block)
- gtag snippet with Consent Mode v2 defaults: `site/index.html` (head)
- Follow-up corrections tracked in #92: `role="region"`, Escape-key dismissal, CSP header, canonical redirect

# Analytics Audit — {project} @ {short-sha}

> Persisted by `/analytics-audit` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

Analytics SDK configuration, event taxonomy, funnel-completeness, dashboard existence. Out of scope: campaign attribution, marketing-mix modelling, BI-team workflows.

## Findings

| # | Area | Status | Detail | Severity |
|---|---|---|---|---|
| E1 | Analytics SDK initialised | PASS | GA4 + PostHog init in `_app.tsx`; consent-aware via Consent Mode v2 | — |
| E2 | Event-naming convention | WARN | Mixed `snake_case` / `camelCase`; some `Title Case`. No documented schema. | medium |
| E3 | Sign-up funnel events | PASS | All 4 steps fire (`signup_view`, `signup_email_entered`, `signup_otp_sent`, `signup_completed`) | — |
| E4 | Activation funnel events | FAIL | First-action event missing — can't measure activation rate | high |
| E5 | Purchase / conversion events | WARN | `purchase_completed` fires but lacks `value` / `currency` props | medium |
| E6 | Dashboards exist | WARN | Acquisition dashboard exists; activation + retention dashboards don't | medium |
| E7 | Event volume sanity check | PASS | Sample week's volume matches expected DAU; no obvious drop-off | — |

## Event taxonomy gap

The schema-less mix in E2 means dashboard authors join on string-matched event names that don't exist. Documented convention should be: `<surface>_<noun>_<verb>` in `snake_case` (e.g. `signup_email_entered`, `dashboard_export_clicked`). One-off audit + sweep covers most files.

## Recommended priority

1. E4 — define + instrument the activation event ("first task created" / "first message sent" / etc — depends on the product). Without it, the activation half of AARRR is blind.
2. E2 — taxonomy doc + naming sweep
3. E5 — `value` + `currency` on purchase events (revenue dashboards depend on it)
4. E6 — activation + retention dashboards (post-instrumentation)

## Notes

(Context: which BI tool the team uses, which funnels are most load-bearing for the business, prior taxonomy refactors.)

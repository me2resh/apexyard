# Monitoring & Observability Audit — {project} @ {short-sha}

> Persisted by `/monitoring-audit` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

Production-readiness observability: structured logging, error tracking, health endpoints, alerting rules, runbooks, incident response. Out of scope: vendor-specific dashboards (those evolve faster than this audit can keep up; check the vendor's own UI).

## Findings

| # | Area | Status | Detail | Severity |
|---|---|---|---|---|
| M1 | Structured logging | WARN | App uses `console.log` not a structured logger (pino / winston / structlog) | medium |
| M2 | Error tracking | FAIL | No Sentry/Datadog/Bugsnag/Rollbar SDK detected; uncaught errors are silent | critical |
| M3 | Health endpoint | FAIL | No `/health` or `/ready`; load balancer can't detect a hung instance | high |
| M4 | Alerting rules | FAIL | No `alerts.yml` / `prometheus.yml` / equivalent; nothing pages on-call | critical |
| M5 | Runbooks | WARN | One incident playbook exists (auth-outage); the other 4 known classes have none | medium |
| M6 | Distributed tracing | WARN | No correlation IDs propagated request → service → DB | medium |
| M7 | On-call rotation | PASS | PagerDuty schedule documented in `docs/oncall.md` | — |

## Recommended priority

1. M2 — wire Sentry (or equivalent) before launch. The cheapest possible "we'll know when it breaks" signal.
2. M4 — at minimum a "site is down" + "error rate >1%" alert. Without these, M2 is shouting into the void.
3. M3 — one-line `/health` endpoint returning HTTP 200; load balancer health checks anchor on it.
4. M1 — structured logger swap (1-2 hour refactor)
5. M5, M6 — runbook + tracing build out post-launch as patterns emerge

## Notes

(Context: SLO targets, on-call team size, prior incidents informing where to invest first.)

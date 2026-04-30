---
name: monitoring-audit
description: Observability and incident readiness audit — logging, error tracking, health endpoints, alerting rules, runbooks, incident response. Deep-dive companion to /launch-check's monitoring dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: medium
---

# /monitoring-audit — Observability & Incident Readiness

Deep-dive observability analysis. Checks that production issues will be detected, alerted on, and resolvable. Invoke when `/launch-check`'s monitoring row shows WARN or FAIL.

## Observability Pillars

| Pillar | Question | What to look for |
|--------|----------|-----------------|
| **Logs** | Can you see what happened? | Structured logging, log levels, no PII in logs |
| **Metrics** | Can you measure what's happening? | Request counts, latency, error rates, business metrics |
| **Traces** | Can you follow a request end-to-end? | Distributed tracing, correlation IDs |
| **Alerts** | Will you know when something breaks? | Alerting rules, on-call, PagerDuty/OpsGenie |

## Process

### Step 1: Error tracking

- Grep for error tracking SDK (Sentry, Datadog, Bugsnag, LogRocket, Rollbar)
- Check initialization: is the SDK configured with the correct DSN/API key (env var, not hardcoded)?
- Check error boundaries (React ErrorBoundary, Vue errorHandler, global uncaughtException handler)
- Check if source maps are uploaded to the error tracker for readable stack traces

### Step 2: Health endpoints

- Check for a health check route (`/health`, `/healthz`, `/api/health`, `/_health`)
- Check what the health endpoint verifies (just "alive"? database connectivity? external service reachability?)
- Check for a readiness probe separate from liveness (Kubernetes-style)

### Step 3: Logging

- Check for a logging library (winston, pino, bunyan, python logging, structured logging)
- Check if logs are structured (JSON) or unstructured (console.log with string concatenation)
- Check for appropriate log levels (error, warn, info, debug) — not everything at `console.log`
- Check that sensitive data (passwords, tokens, PII) is NOT logged

### Step 4: Alerting and incident response

- Check for alerting configuration (CloudWatch Alarms, Datadog monitors, PagerDuty rules)
- Check for a runbook (`docs/runbook.md`, `docs/incident-response.md`, `RUNBOOK.md`)
- Check for a status page configuration (Statuspage.io, Instatus, or self-hosted)

### Step 5: Output

```
MONITORING AUDIT — <project> @ <sha>

| # | Pillar | Status | Finding |
|----|--------|--------|---------|
| M1 | Error tracking | PASS | Sentry configured in lib/sentry.ts, source maps uploaded |
| M2 | Health endpoint | FAIL | No /health route found |
| M3 | Logging | WARN | Using console.log (unstructured), no log levels |
| M4 | Alerting | WARN | No alerting rules found in code or IaC |
| M5 | Runbook | FAIL | No runbook or incident response doc |

Incident readiness: NOT READY (2 fails — health endpoint and runbook are minimum viable)

Priority fixes:
  1. [ ] Add GET /health returning { status: "ok", db: "connected" }
  2. [ ] Create docs/runbook.md with deployment, rollback, and common-issue procedures
  3. [ ] Replace console.log with structured logger (pino recommended for Node.js)
```

## Rules

1. **Auto-PASS for projects not yet in production.** Pre-launch monitoring gaps are expected — flag them as "set up before first deploy" rather than "FAIL."
2. **Check IaC too.** Alerting rules might be in Terraform, CloudFormation, or CDK files rather than application code.
3. **Don't require all four pillars.** Logs + error tracking + health endpoint is the minimum. Distributed tracing and detailed metrics are "nice to have" for most teams.
4. **Be specific about what the health endpoint should check** — "returns 200" is table stakes; checking database connectivity is the real test.

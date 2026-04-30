---
name: threat-model
description: Full STRIDE threat modelling exercise — identifies Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, and Elevation of Privilege surfaces across the codebase. Deep-dive companion to /launch-check's security dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: high
---

# /threat-model — STRIDE Threat Modelling

Deep-dive security analysis using the STRIDE framework. Produces a prioritized threat catalogue with mitigations. This is the expert companion to `/launch-check`'s security row — invoke it when security shows WARN or FAIL, or proactively before any launch.

## STRIDE Categories

| Category | Question | What to look for |
|----------|----------|-----------------|
| **S**poofing | Can an attacker pretend to be someone else? | Auth implementation, session management, token validation, API key handling |
| **T**ampering | Can data be modified in transit or at rest? | Input validation, CSRF protection, data integrity checks, signed tokens |
| **R**epudiation | Can actions be denied after the fact? | Audit logging, action trails, non-repudiation mechanisms |
| **I**nformation Disclosure | Can sensitive data leak? | Error messages, logs, API responses, hardcoded secrets, .env exposure, debug mode |
| **D**enial of Service | Can the system be overwhelmed? | Rate limiting, input size limits, resource exhaustion, recursive queries |
| **E**levation of Privilege | Can a user gain unauthorized access? | Role checks, admin routes, authorization middleware, IDOR vulnerabilities |

## Process

### Step 1: Map the attack surface

Read the codebase and identify:

- **Entry points**: API routes, form handlers, WebSocket endpoints, file upload handlers
- **Data stores**: databases, caches, file systems, environment variables
- **External integrations**: third-party APIs, payment processors, email services, auth providers
- **Trust boundaries**: client ↔ server, server ↔ database, server ↔ external API

### Step 2: Apply STRIDE to each entry point

For each entry point, ask all 6 STRIDE questions. Record findings by severity:

| Severity | Meaning | Action |
|----------|---------|--------|
| **CRITICAL** | Exploitable now, data at risk | Fix before launch, no exceptions |
| **HIGH** | Likely exploitable, significant impact | Fix before launch |
| **MEDIUM** | Possible exploit, moderate impact | Fix in next sprint |
| **LOW** | Theoretical risk, minimal impact | Track, fix when convenient |

### Step 3: Output the threat catalogue

```
THREAT MODEL — <project> @ <sha>

Attack surface: <N> entry points, <N> data stores, <N> external integrations

| # | Category | Threat | Severity | Entry point | Mitigation |
|----|----------|--------|----------|-------------|------------|
| T1 | Spoofing | No rate limit on login | HIGH | POST /auth/login | Add rate limiter (5/min/IP) |
| T2 | Info Disc | API returns stack traces in prod | MEDIUM | Global error handler | Strip stack traces when NODE_ENV=production |
| T3 | Tampering | No CSRF token on state-changing forms | HIGH | POST /settings | Add CSRF middleware |
| ...| ... | ... | ... | ... | ... |

Summary: <N> threats found (<N> critical, <N> high, <N> medium, <N> low)

Recommended priority:
  1. [ ] T1 — rate limit on login (HIGH, easy fix)
  2. [ ] T3 — CSRF protection (HIGH, middleware addition)
  3. [ ] T2 — strip stack traces (MEDIUM, config change)
```

### Step 4: Check common OWASP patterns

After the STRIDE sweep, explicitly check for:

- SQL/NoSQL injection (parameterized queries? ORM used consistently?)
- XSS (dangerouslySetInnerHTML, v-html, template literals in HTML?)
- Insecure deserialization (JSON.parse on untrusted input without validation?)
- Security misconfiguration (CORS *, debug mode, default credentials?)
- Using components with known vulnerabilities (`npm audit` / `pip audit`)

## Rules

1. **Lead with the summary table.** Details (code snippets, exploit scenarios) go AFTER the table, organized by severity.
2. **Be specific about mitigations.** "Add auth" is not a mitigation. "Add JWT verification middleware to routes /api/admin/* using the existing authMiddleware.ts" is.
3. **Don't cry wolf.** Only flag threats that are realistic for this codebase. A static site doesn't need CSRF protection.
4. **Adapt scope to project type.** API-only? Focus on auth, input validation, rate limiting. Full-stack? Add XSS, CSRF, cookie security. Library? Focus on supply chain and input handling.

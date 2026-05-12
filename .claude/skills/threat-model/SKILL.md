---
name: threat-model
description: Full STRIDE threat modelling exercise — identifies Spoofing, Tampering, Repudiation, Information Disclosure, Denial of Service, and Elevation of Privilege surfaces across the codebase. Deep-dive companion to /launch-check's security dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: high
---

# /threat-model — STRIDE Threat Modelling

Deep-dive security analysis using the STRIDE framework. Produces a prioritized threat catalogue with mitigations. This is the expert companion to `/launch-check`'s security row — invoke it when security shows WARN or FAIL, or proactively before any launch.

## LSP-aware (optional, recommended)

This skill performs semantic code navigation — finding definitions, walking references, tracing handlers across modules. With LSP enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`), queries are ~3-15× cheaper in token cost than grep + Read on shallow lookups, and ~1.4-5× cheaper on multi-hop traces. Without LSP, the skill falls back to grep + Read transparently — no new failure mode, just optional speed.

Per-language LSP plugins live in Claude Code's marketplace. Install once; the skill detects the active language and dispatches automatically.

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

**Populate the Data Flow Diagram first** in this run's per-run artefact (per `templates/audits/threat-model.md` § Data Flow Diagram) — replace the Mermaid skeleton's placeholders with the system's actual external entities, processes, data stores, and trust boundaries, and label every arrow with the data that crosses it. The STRIDE walk in Step 2 then iterates the DFD's trust-boundary crossings rather than inventing threats ad-hoc.

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

### Step 5: Persist the run + render trend

After printing the human-readable catalogue (Step 3) and OWASP check (Step 4), persist a structured artefact via the shared audit-history lib so the threat-model trend across runs becomes legible. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

#### 5a. Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`. If the project isn't registered, use the basename of the project path and tell the operator to `/handover` it for cross-machine trend continuity.

Compute a single headline score from the severity distribution:

```
score = max(0, 100 - 25*critical - 10*high - 3*medium - 1*low)
```

Compute the verdict by the worst-severity rule:

| Worst severity present | Verdict |
|---|---|
| critical or high       | `fail` |
| medium only            | `conditional` |
| low only / none        | `pass` |

#### 5b. Build payload + body, persist via the lib

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Lowercase severity in the payload — the lib's stats derivation expects
# critical / high / medium / low / info. The visible catalogue from Step 3
# can keep whatever capitalisation reads best.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "findings": [
    {"id": "T1", "severity": "high",   "status": "open", "summary": "No rate limit on /auth/login"},
    {"id": "T2", "severity": "medium", "status": "open", "summary": "Stack traces in prod errors"},
    {"id": "T3", "severity": "high",   "status": "open", "summary": "No CSRF on state-changing forms"}
  ]
}
EOF

# Body = the catalogue table + OWASP cross-check (per templates/audits/threat-model.md).
body=$(mktemp); cat > "$body" <<'EOF'
## Attack surface

3 entry points, 1 data store, 0 external integrations.

## Threats by STRIDE category

| # | Category | Threat | Severity | Entry point | Mitigation |
|---|---|---|---|---|---|
| T1 | Spoofing | No rate limit on /auth/login | high | POST /auth/login | Add rate limiter (5/min/IP) |
| T2 | Info Disclosure | Stack traces in prod errors | medium | Global error handler | Strip when NODE_ENV=production |
| T3 | Tampering | No CSRF on state-changing forms | high | POST /settings | Add CSRF middleware |

## Recommended priority

1. T1 — rate limit on /auth/login
2. T3 — CSRF middleware
3. T2 — strip stack traces

## OWASP cross-check

(... per Step 4 results ...)
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "threat-model" "$ts" "fail" 65 "$body" < "$payload"
rm -f "$payload" "$body"
```

#### 5c. Render the trend section

```bash
audit_render_trend "<project-name>" "threat-model" 5
```

- < 2 prior runs → silent (no trend section). Don't append anything.
- ≥ 2 prior runs → prints a markdown trend block (heading + table + ASCII chart of `score` over time) to stdout. Append it to this run's MD artefact and to the chat output.

#### 5d. Opt-in commit (history-tracked marker)

By default the dimension's runs/ JSON files are gitignored — most adopters don't want audit history bloat in the repo. The lib applies a `.gitignore` based on the presence of the marker:

```bash
# Opt in to commit threat-model history (per-project, per-dimension)
touch projects/<name>/audits/threat-model/.audit-history-tracked
```

The lib re-evaluates the marker on every persist; the operator can toggle freely. The MD artefacts at `<dim_dir>/<ts>.md` are committed regardless — they are the durable human-readable artefact.

## Rules

1. **Lead with the summary table.** Details (code snippets, exploit scenarios) go AFTER the table, organized by severity.
2. **Be specific about mitigations.** "Add auth" is not a mitigation. "Add JWT verification middleware to routes /api/admin/* using the existing authMiddleware.ts" is.
3. **Don't cry wolf.** Only flag threats that are realistic for this codebase. A static site doesn't need CSRF protection.
4. **Adapt scope to project type.** API-only? Focus on auth, input validation, rate limiting. Full-stack? Add XSS, CSRF, cookie security. Library? Focus on supply chain and input handling.
5. **Always persist.** Step 5 always writes a JSON + MD pair via `audit_run_persist`, regardless of opt-in commit state. The marker only controls whether the JSON is committed; persistence is unconditional so the trend is visible across runs.
6. **Severity vocabulary in the JSON is lowercase.** The lib's `stats.by_severity` derivation expects `critical` / `high` / `medium` / `low` / `info`. The human-readable Step 3 table can use whatever capitalisation reads best.

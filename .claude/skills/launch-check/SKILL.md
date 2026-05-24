---
name: launch-check
description: Production readiness audit — 10-dimension go/no-go sweep (security, a11y, compliance, analytics, SEO, GEO, perf, monitoring, docs, behaviour-quality).
disable-model-invocation: false
argument-hint: "[project-path] | trend [project-path]"
effort: high
---

# /launch-check — Production Readiness Audit

Runs a 10-dimension sweep against a project and outputs a one-page verdict. Designed for milestone boundaries — epic completion, release cuts, launch prep — not per-PR use.

**Invoke from** the project's workspace directory (`cd workspace/<project>/`) or pass the path as an argument: `/launch-check workspace/my-app`.

**Two modes:**

- `/launch-check [project-path]` — full audit (default). Runs all 10 dimensions, persists results to the per-project history store, and renders a "Trend (last 5 runs)" section when ≥ 2 prior runs exist.
- `/launch-check trend [project-path]` — read-only trend report. Renders just the trend section from existing run files. Useful for "are we trending up?" without burning the audit cost. See § "Trend-only mode" below.

## Deep-dive companions

Each dimension has a dedicated expert skill for when you need to go deeper than the one-line summary. The launch check is the overview; the expert skills are the investigation.

| Dimension | Quick check | Deep dive |
|-----------|------------|-----------|
| Security | `/launch-check` row 1 | **`/threat-model`** — full STRIDE threat modelling exercise |
| Accessibility | `/launch-check` row 2 | **`/accessibility-audit`** — WCAG 2.1 AA compliance audit |
| Compliance | `/launch-check` row 3 | **`/compliance-check`** — GDPR + ePrivacy analysis |
| Analytics | `/launch-check` row 4 | **`/analytics-audit`** — event taxonomy and funnel coverage |
| SEO | `/launch-check` row 5 | **`/seo-audit`** — technical SEO against Google best practices |
| Generative-engine | `/launch-check` row 6 | **`/geo-audit`** — LLM/agent discoverability (GEO + AEO), `llms.txt`, `AGENTS.md`, AI-crawler directives, JSON-LD citation grounding |
| Performance | `/launch-check` row 7 | **`/performance-audit`** — bundle, images, Core Web Vitals |
| Monitoring | `/launch-check` row 8 | **`/monitoring-audit`** — observability and incident readiness |
| Documentation | `/launch-check` row 9 | **`/docs-audit`** — Diataxis framework completeness |
| Behaviour quality | `/launch-check` row 10 | **`/mutation-test`** — mutation-testing sensor; measures whether the test suite constrains behaviour, not just executes lines |

When a dimension shows WARN or FAIL, tell the user: *"For a detailed analysis, run `/threat-model`"* (or the relevant expert skill).

## Output format

The output should be **scannable in 10 seconds**. One table, one verdict, one blockers list:

```
LAUNCH CHECK — <project> @ <sha> (<date>)

| #  | Dimension          | Status | Finding                              |
|----|--------------------|--------|--------------------------------------|
| 1  | Security           | PASS   | No critical vulns, auth flow ok      |
| 2  | Accessibility      | WARN   | 3 images missing alt text            |
| 3  | Compliance         | FAIL   | No cookie consent banner detected    |
| 4  | Analytics          | PASS   | GA4 configured, 12 events tracked    |
| 5  | SEO                | WARN   | Missing og:image on 2 pages          |
| 6  | Generative-engine  | WARN   | No llms.txt, AGENTS.md missing       |
| 7  | Performance        | PASS   | Bundle < 200KB, LCP < 2.5s          |
| 8  | Monitoring         | FAIL   | No health check endpoint found       |
| 9  | Documentation      | PASS   | README updated this week             |
| 10 | Behaviour quality  | WARN   | Mutation score 54% (threshold 60%)   |

Verdict: CONDITIONAL GO (2 failures need resolution)

Blocking:
  - [ ] Add cookie consent banner (compliance)
  - [ ] Add /health endpoint (monitoring)

Warnings (non-blocking, address before next launch):
  - [ ] Add alt text to 3 images (accessibility)
  - [ ] Add og:image to landing and pricing pages (SEO)
```

**Do NOT dump hundreds of lines.** Each dimension gets ONE row in the table. Details go in follow-up messages only if the user asks "tell me more about the security findings" — not upfront.

## Verdict logic

| Condition | Verdict |
|-----------|---------|
| All dimensions PASS | **GO** — ready to launch |
| Some WARN, zero FAIL | **GO with warnings** — launch is safe, address warnings before next milestone |
| Any FAIL | **CONDITIONAL GO** — resolve the blocking items before launch |
| 3+ FAIL or any critical security finding | **NO-GO** — significant gaps, not launch-ready |

## The 9 dimensions

### 1. Security

**What to check:**

- Run `npm audit` / `pip audit` / equivalent for dependency vulnerabilities
- Grep for hardcoded secrets, API keys, tokens (same patterns as `check-secrets.sh` but against the full codebase, not just staged files)
- Check auth flow: is there authentication? Is it using a reputable provider (Cognito, Auth0, Firebase Auth)? Are tokens stored securely (httpOnly cookies, not localStorage)?
- Check for common OWASP risks: SQL/NoSQL injection surfaces, XSS vectors (dangerouslySetInnerHTML, v-html), CSRF protection
- Check HTTPS enforcement, CORS configuration, security headers

**PASS if:** no critical vulns, auth uses a reputable provider, no hardcoded secrets, basic OWASP surface clean.
**WARN if:** medium vulns in dependencies, or missing security headers.
**FAIL if:** critical vuln, hardcoded secrets found, no auth on a user-facing app, or obvious injection surface.

### 2. Accessibility

**What to check:**

- Grep for `<img` tags without `alt` attributes
- Check for semantic HTML: `<main>`, `<nav>`, `<header>`, `<footer>`, heading hierarchy (h1 → h2 → h3)
- Check for `aria-label` on interactive elements without visible text
- Check color contrast: look for low-contrast color combinations in CSS/theme files
- Check keyboard navigation: are there `onClick` handlers without corresponding `onKeyDown`?
- Check for `<html lang="...">` attribute

**PASS if:** all images have alt text, semantic HTML used, no obvious contrast issues.
**WARN if:** a few missing alt texts, or minor semantic gaps.
**FAIL if:** systematic missing alt text, no semantic HTML at all, or no lang attribute.

### 3. Compliance

**What to check:**

- Cookie consent: grep for cookie-consent libraries (cookieconsent, react-cookie-consent, etc.) or a consent banner component
- Privacy policy: check for a `/privacy` route or `privacy-policy` page
- Terms of service: check for a `/terms` route
- GDPR: if the app collects user data, is there a data deletion mechanism? Check for a "delete account" route or endpoint
- Data retention: is there a documented policy? (Can be in docs/ or in the privacy policy)

**PASS if:** cookie consent present, privacy policy exists, terms exist.
**WARN if:** privacy policy exists but no data deletion mechanism.
**FAIL if:** no cookie consent on a site that uses cookies, or no privacy policy on a user-facing app.

### 4. Analytics

**What to check:**

- Grep for analytics SDK initialization (Google Analytics/GA4, Mixpanel, Amplitude, PostHog, Plausible)
- Check for event tracking calls (gtag, track, capture, etc.)
- Check for a config file or environment variable pointing to an analytics dashboard
- If no analytics at all and the project is user-facing: that's a finding

**PASS if:** analytics SDK configured and events are being tracked.
**WARN if:** SDK configured but few/no custom events (only page views).
**FAIL if:** user-facing app with zero analytics. (Non-user-facing like CLIs/libraries: auto-PASS.)

### 5. SEO

**What to check:**

- Check for `<title>` and `<meta name="description">` on key pages
- Check for `<meta property="og:title">`, `og:description`, `og:image` (Open Graph)
- Check for `sitemap.xml` at the expected location
- Check for `robots.txt`
- Check for canonical URLs (`<link rel="canonical">`)
- Check for structured data (JSON-LD, schema.org)

**PASS if:** title + description + OG tags on main pages, sitemap exists, robots.txt exists.
**WARN if:** missing OG tags on some pages, or no structured data.
**FAIL if:** no title/description on the main page, or no robots.txt. (Non-web projects: auto-PASS.)

### 6. Generative-engine (LLM/agent discoverability)

**What to check** (quick scan — full deep-dive lives in `/geo-audit`):

- `llms.txt` and `llms-full.txt` at the site root
- `AGENTS.md` at the repo root
- AI-crawler directives in `robots.txt` (does it name `GPTBot`, `ClaudeBot`, `PerplexityBot`, etc.?)
- JSON-LD citation metadata on article-shaped pages (`author`, `dateModified`, `datePublished`, `publisher`)
- Per-page token count for the largest docs page (heuristic: `char_count / 4` — flag pages over 25K)

Covers two related sub-scopes: **GEO** (LLM citations — ChatGPT, Claude, Perplexity, Gemini) and **AEO** (coding-agent consumption — Claude Code, Cursor, Aider, Cline). Both consume the same artefacts, so they share one row at the milestone-boundary level. For the bucket-by-bucket breakdown, run `/geo-audit`.

**PASS if:** `llms.txt` present, `AGENTS.md` present with sandbox + MCP sections, JSON-LD citation metadata on key pages.
**WARN if:** some artefacts missing (e.g. `AGENTS.md` exists but lacks sandbox links).
**FAIL if:** no `llms.txt` AND no `AGENTS.md` AND no citation JSON-LD on a content-heavy site. (Non-web projects: auto-PASS.)

### 7. Performance

**What to check:**

- If there's a build output: check bundle size (look for `dist/`, `build/`, `.next/`)
- Check for image optimization: are images served as WebP/AVIF? Are there large unoptimized images (> 500KB)?
- Check for lazy loading on below-the-fold images (`loading="lazy"`)
- Check for code splitting (dynamic imports, React.lazy)
- If there's a Lighthouse config or Web Vitals tracking: check the targets

**PASS if:** bundle under 300KB gzipped, images optimized, lazy loading present.
**WARN if:** bundle 300-500KB, or a few large images.
**FAIL if:** bundle > 1MB, or systematically unoptimized images. (Non-web: auto-PASS.)

### 8. Monitoring

**What to check:**

- Grep for error tracking SDK (Sentry, Datadog, Bugsnag, LogRocket)
- Check for a health check endpoint (`/health`, `/healthz`, `/api/health`)
- Check for alerting configuration (PagerDuty, OpsGenie, CloudWatch Alarms, or alerting rules in code)
- Check for a runbook or incident response doc (`docs/runbook.md`, `docs/incident-response.md`)
- Check for logging configuration (structured logging, log levels)

**PASS if:** error tracking configured, health endpoint exists, some alerting in place.
**WARN if:** error tracking but no health endpoint, or no runbook.
**FAIL if:** no error tracking at all on a production app, or no health endpoint.

### 9. Documentation

**What to check:**

- README.md exists and is not the default template
- README has: project description, setup instructions, how to run locally, how to deploy
- API documentation: if there's an API, is it documented? (OpenAPI spec, Swagger, or doc comments)
- Deployment guide: how to deploy to staging/production
- Changelog: is there a CHANGELOG.md or are releases documented?
- Check for staleness: compare README last-modified date with recent code changes

**PASS if:** README has setup + run + deploy instructions, and was updated recently.
**WARN if:** README exists but is stale (> 30 days behind code changes), or API undocumented.
**FAIL if:** no README, or README is the default GitHub template.

### 10. Behaviour quality (mutation testing)

**What to check** (quick gate — full deep-dive lives in `/mutation-test`):

- Read `.claude/project-config.json → mutation.threshold` (default 60% from `.claude/project-config.defaults.json`)
- Check whether a recent mutation report exists at `projects/<name>/quality/mutation-<YYYY-MM-DD>.md` (within the last 30 days)
- If the latest report's score < threshold → **WARN** (not FAIL — mutation is a leading indicator, not a launch blocker)
- If **no recent report exists**, *offer* to dispatch to `/mutation-test` for a fresh run, but do **NOT** auto-run it during `/launch-check`. A mutation audit takes 20–40 minutes on a medium codebase — too slow to fold into the milestone-boundary sweep silently. The dimension reports **WARN** with the finding "no recent mutation report (run `/mutation-test` for a fresh number)".
- If `mutation.runner` is `null` or the project's primary language has no recognised mutation runner installed: **auto-PASS** (the audit doesn't apply — same shape as SEO auto-PASS for non-web projects). Surface the gap as `INFO` in the finding column.

**PASS if:** recent mutation report exists AND score ≥ threshold.
**WARN if:** recent mutation report exists BUT score < threshold, OR no recent report (operator should run `/mutation-test`).
**FAIL if:** never — mutation testing is advisory, not a launch blocker. See AgDR-0045 for the rationale.

Auto-PASS for projects without a mutation runner installed (or where the language has no recognised dispatch — e.g. Rust at v1).

## Process

### Step 1: Determine the project

If invoked with an argument, use that path. Otherwise, use the current working directory. Verify it's a git repo with source code (not the ops repo itself — the launch check is for managed projects, not for apexyard).

### Step 2: Quick scan

Read the project's structure to determine what checks apply:

- Is it a web app? (has `index.html`, React/Vue/Svelte/Next.js markers) → all 9 dimensions
- Is it an API only? (has routes/endpoints but no frontend) → skip accessibility, SEO, generative-engine, performance (auto-PASS)
- Is it a CLI/library? → skip accessibility, compliance, analytics, SEO, generative-engine, performance (auto-PASS on those)
- Is it a mobile app? → adjust accessibility checks for mobile, skip SEO, skip generative-engine

### Step 3: Run each applicable dimension

Go through each dimension in order. For each:

1. Run the checks listed above (grep, file existence, SDK detection)
2. Classify as PASS / WARN / FAIL based on the criteria
3. Write a one-line finding for the table

**Do NOT spend more than 30 seconds per dimension.** The checks should be quick grepping and file scanning, not deep code review. Deep dives happen in the dedicated companion skill (`/seo-audit`, `/geo-audit`, `/threat-model`, etc.) — not inside the initial sweep.

### Step 4: Compile the verdict

Count PASS/WARN/FAIL, apply the verdict logic, format the output table.

### Step 5: Output

Print the table exactly as shown in the "Output format" section above. Then continue to Step 6 to persist the run and render the trend section.

**Do NOT auto-create tickets for the findings.** Offer: "Want me to create tickets for the blocking items?" — but let the user decide. The launch check is advisory.

### Step 6: Persist the run + render the trend

After the verdict table, persist this run to the project's history store via the shared audit-history lib and append a trend section if there are ≥ 2 prior runs.

This step was refactored as part of #218 to consume `_lib-audit-history.sh` (the same lib that powers `/threat-model`, `/security-review`, and the other audit skills). Behaviour is preserved: the JSON schema is the same superset shape, the chart is rendered by the same `render-trend.sh` (dispatched from inside the lib), and adopters' existing run-history at the legacy path is still picked up by the trend renderer.

#### 6a. Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`. If the project isn't registered (e.g. someone runs `/launch-check` on a directory that's never been onboarded), use the basename of the project path; tell the operator to `/handover` it for cross-machine trend continuity.

The headline score is the unweighted mean of `scores.*`, rounded to int. The verdict is one of `go` / `go-with-warnings` / `conditional-go` / `no-go` (launch-check-specific four-state vocabulary, preserved from the existing skill).

#### 6b. Build payload + body, persist via the lib

The lib's `audit_run_persist` accepts arbitrary stdin JSON and augments it with top-level `ts` / `dimension` / `verdict` / `score` fields, then writes both a JSON file and an MD file. For launch-check the JSON payload is a SUPERSET — it includes the legacy `scores{}` map (for `render-trend.sh` to plot) AND a derived `findings[]` array (for the canonical schema):

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-audit-history.sh"

# Map each scored dimension to a Finding for the canonical schema.
# Severity from score: ≥85 info, 70-84 low, 55-69 medium, 40-54 high, <40 critical.
payload=$(mktemp); cat > "$payload" <<'EOF'
{
  "schema_version": 1,
  "branch": "main",
  "commit": "abc1234",
  "scores": {
    "security": 88, "accessibility": 94, "compliance": 76,
    "analytics": 90, "seo": 87, "generative_engine": 64,
    "performance": 68, "monitoring": 83, "docs": 91
  },
  "top_risks": ["No cookie consent banner", "Missing /health endpoint"],
  "findings": [
    {"id": "compliance",  "severity": "low",    "status": "open", "summary": "compliance score 76 — cookie consent banner missing"},
    {"id": "performance", "severity": "medium", "status": "open", "summary": "performance score 68 — bundle > 250KB"}
  ]
}
EOF

# Body: the human-readable per-run summary launch-check already produces.
body=$(mktemp); cat > "$body" <<'EOF'
## Launch-check verdict: conditional-go

| Dimension       | Score | Status |
|-----------------|-------|--------|
| Security        | 88    | PASS   |
| Accessibility   | 94    | PASS   |
| Compliance      | 76    | WARN   |
| ...             | ...   | ...    |

## Top risks

1. No cookie consent banner
2. Missing /health endpoint

## Recommendations

(...)
EOF

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
audit_run_persist "<project-name>" "launch-check" "$ts" "conditional-go" 84 "$body" < "$payload"
rm -f "$payload" "$body"
```

`audit_run_persist` writes:

- `projects/<name>/audits/launch-check/runs/<ts>.json` — JSON with everything the lib added on top of the payload (top-level `ts`, `dimension: launch-check`, `verdict`, `score`, `schema_version`) AND everything in the original payload (`scores{}`, `branch`, `commit`, `top_risks[]`, `findings[]`, derived `stats{}`)
- `projects/<name>/audits/launch-check/<ts>.md` — frontmatter + the body above
- `projects/<name>/audits/launch-check/.gitignore` — driven by the per-dim `.audit-history-tracked` marker presence

**JSON schema is a SUPERSET.** The canonical fields (`ts`, `dimension`, `verdict`, `score`, `findings[]`, `stats{}`, `schema_version`) coexist with the launch-check-specific fields (`scores{}`, `branch`, `commit`, `top_risks[]`). The legacy `render-trend.sh` reads `ts` / `scores` / `verdict` and works unchanged. The new generic `audit_render_trend` reads `ts` / `score` / `verdict` and works for the rest of the audit family.

#### 6c. Render the trend section

```bash
audit_render_trend "<project-name>" "launch-check" 5
```

- The lib internally dispatches to `render-trend.sh` for the `launch-check` dimension — byte-equal output to the pre-#218 chart (mean of `scores.*` on Y-axis, score-delta notes, ASCII chart).
- Crucially, the lib's `audit_run_list` merges JSON from the canonical path (`projects/<name>/audits/launch-check/runs/`) AND the legacy path (`projects/<name>/launch-check/runs/`) — so adopters' existing history continues to render across the migration. No `mv` required.
- Output is a markdown trend block (heading + table + ASCII chart). Append it to this run's MD artefact and to the chat output.

#### 6d. Opt-in commit (history-tracked marker)

The per-dimension marker (`.audit-history-tracked`) sits inside the dimension's audit dir and controls whether `runs/*.json` files are gitignored:

```bash
# Opt in to commit launch-check history
touch projects/<name>/audits/launch-check/.audit-history-tracked
```

The lib re-evaluates the marker on every persist; toggling is free. The MD artefact at `<dim_dir>/<ts>.md` is committed regardless — that's the durable human-readable artefact.

**Migration note for adopters with existing history:** the legacy marker at `projects/<name>/launch-check/.launch-check-history-tracked` continues to apply to that path's `runs/`. To consolidate trees, `mv projects/<name>/launch-check/* projects/<name>/audits/launch-check/` after backing up; the lib's renderer will read the consolidated tree on the next run. Consolidation is optional — the read-merge happens transparently if you leave both trees in place.

## Trend-only mode — `/launch-check trend [project-path]`

Read-only mode that produces just the trend section (no full audit, no per-dimension grep). Useful for "are we trending up?" without re-running the costly sweep.

Process:

1. Source `_lib-audit-history.sh` (same as Step 6).
2. Call `audit_render_trend "<project-name>" "launch-check" 5`. The lib reads both the canonical path AND the legacy path; if the merged set has < 2 runs the call is silent and you tell the operator there's no trend yet.
3. Print the renderer's output.

Do NOT run the 9-dimension sweep in this mode. Do NOT write any new JSON. This mode is purely for reviewing existing history.

## Rules

1. **Scannable in 10 seconds.** One table, one verdict, one blockers list. No walls of text.
2. **One row per dimension.** Details on demand, not upfront.
3. **30 seconds per dimension.** Quick grep and file scanning, not deep code review.
4. **Auto-PASS non-applicable dimensions.** A CLI doesn't need a cookie banner.
5. **Advisory, not blocking.** The user decides go/no-go based on the findings. The skill does NOT block deploys mechanically.
6. **Don't create tickets unprompted.** Offer to create them. Let the user decide.
7. **Run from the project directory.** The skill checks `workspace/<project>/`, not the ops repo.
8. **Persist every run via the lib.** Step 6 always calls `audit_run_persist`, regardless of opt-in commit state. The `.audit-history-tracked` marker only controls whether the JSON files are committed; the MD artefacts are committed unconditionally and persistence happens on every run.
9. **Resolve paths via the lib.** `audit_resolve_dir` (inside `_lib-audit-history.sh`) calls `portfolio_projects_dir` for you — the SKILL doesn't need to source the portfolio helper directly any more.

## Implementation notes

Persistence + trend logic ships as a shared shell helper that all audit skills consume:

| File | Purpose |
|------|---------|
| `.claude/hooks/_lib-audit-history.sh` | Audit-history library shared with /threat-model, /security-review, etc. (4 functions: `audit_resolve_dir`, `audit_run_persist`, `audit_run_list`, `audit_render_trend`) |
| `render-trend.sh` (this skill's dir) | Legacy chart renderer for the launch-check dimension; the lib's `audit_render_trend` dispatches to it when the dimension is `launch-check` so the chart shape stays byte-equal across the #218 refactor |

Design rationale:

- ASCII chart vs Mermaid, JSON schema choice, opt-in commit marker: see [`docs/agdr/AgDR-0014-launch-check-trend-tracking.md`](../../../docs/agdr/AgDR-0014-launch-check-trend-tracking.md)
- Audit-history lib shape, JSON+MD pair, launch-check backward-compat strategy: see [`docs/agdr/AgDR-0019-audit-artefact-persistence.md`](../../../docs/agdr/AgDR-0019-audit-artefact-persistence.md) and [`docs/technical-designs/audit-artefact-persistence.md`](../../../docs/technical-designs/audit-artefact-persistence.md)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

---
name: launch-check
description: Production readiness audit — runs a multi-dimension sweep (security, accessibility, compliance, analytics, SEO, performance, monitoring, docs) and outputs a scored go/conditional-go/no-go verdict. Use at milestone boundaries, not on every PR.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: high
---

# /launch-check — Production Readiness Audit

Runs an 8-dimension sweep against a project and outputs a one-page verdict. Designed for milestone boundaries — epic completion, release cuts, launch prep — not per-PR use.

**Invoke from** the project's workspace directory (`cd workspace/<project>/`) or pass the path as an argument: `/launch-check workspace/my-app`.

## Deep-dive companions

Each dimension has a dedicated expert skill for when you need to go deeper than the one-line summary. The launch check is the overview; the expert skills are the investigation.

| Dimension | Quick check | Deep dive |
|-----------|------------|-----------|
| Security | `/launch-check` row 1 | **`/threat-model`** — full STRIDE threat modelling exercise |
| Accessibility | `/launch-check` row 2 | **`/accessibility-audit`** — WCAG 2.1 AA compliance audit |
| Compliance | `/launch-check` row 3 | **`/compliance-check`** — GDPR + ePrivacy analysis |
| Analytics | `/launch-check` row 4 | **`/analytics-audit`** — event taxonomy and funnel coverage |
| SEO | `/launch-check` row 5 | **`/seo-audit`** — technical SEO against Google best practices |
| Performance | `/launch-check` row 6 | **`/performance-audit`** — bundle, images, Core Web Vitals |
| Monitoring | `/launch-check` row 7 | **`/monitoring-audit`** — observability and incident readiness |
| Documentation | `/launch-check` row 8 | **`/docs-audit`** — Diataxis framework completeness |

When a dimension shows WARN or FAIL, tell the user: *"For a detailed analysis, run `/threat-model`"* (or the relevant expert skill).

## Output format

The output should be **scannable in 10 seconds**. One table, one verdict, one blockers list:

```
LAUNCH CHECK — <project> @ <sha> (<date>)

| #  | Dimension       | Status | Finding                              |
|----|-----------------|--------|--------------------------------------|
| 1  | Security        | PASS   | No critical vulns, auth flow ok      |
| 2  | Accessibility   | WARN   | 3 images missing alt text            |
| 3  | Compliance      | FAIL   | No cookie consent banner detected    |
| 4  | Analytics       | PASS   | GA4 configured, 12 events tracked    |
| 5  | SEO             | WARN   | Missing og:image on 2 pages          |
| 6  | Performance     | PASS   | Bundle < 200KB, LCP < 2.5s          |
| 7  | Monitoring      | FAIL   | No health check endpoint found       |
| 8  | Documentation   | PASS   | README updated this week             |

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

## The 8 dimensions

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

### 6. Performance

**What to check:**

- If there's a build output: check bundle size (look for `dist/`, `build/`, `.next/`)
- Check for image optimization: are images served as WebP/AVIF? Are there large unoptimized images (> 500KB)?
- Check for lazy loading on below-the-fold images (`loading="lazy"`)
- Check for code splitting (dynamic imports, React.lazy)
- If there's a Lighthouse config or Web Vitals tracking: check the targets

**PASS if:** bundle under 300KB gzipped, images optimized, lazy loading present.
**WARN if:** bundle 300-500KB, or a few large images.
**FAIL if:** bundle > 1MB, or systematically unoptimized images. (Non-web: auto-PASS.)

### 7. Monitoring

**What to check:**

- Grep for error tracking SDK (Sentry, Datadog, Bugsnag, LogRocket)
- Check for a health check endpoint (`/health`, `/healthz`, `/api/health`)
- Check for alerting configuration (PagerDuty, OpsGenie, CloudWatch Alarms, or alerting rules in code)
- Check for a runbook or incident response doc (`docs/runbook.md`, `docs/incident-response.md`)
- Check for logging configuration (structured logging, log levels)

**PASS if:** error tracking configured, health endpoint exists, some alerting in place.
**WARN if:** error tracking but no health endpoint, or no runbook.
**FAIL if:** no error tracking at all on a production app, or no health endpoint.

### 8. Documentation

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

## Process

### Step 1: Determine the project

If invoked with an argument, use that path. Otherwise, use the current working directory. Verify it's a git repo with source code (not the ops repo itself — the launch check is for managed projects, not for apexstack).

### Step 2: Quick scan

Read the project's structure to determine what checks apply:

- Is it a web app? (has `index.html`, React/Vue/Svelte/Next.js markers) → all 8 dimensions
- Is it an API only? (has routes/endpoints but no frontend) → skip accessibility, SEO, performance (auto-PASS)
- Is it a CLI/library? → skip accessibility, compliance, analytics, SEO, performance (auto-PASS on those)
- Is it a mobile app? → adjust accessibility checks for mobile, skip SEO

### Step 3: Run each applicable dimension

Go through each dimension in order. For each:

1. Run the checks listed above (grep, file existence, SDK detection)
2. Classify as PASS / WARN / FAIL based on the criteria
3. Write a one-line finding for the table

**Do NOT spend more than 30 seconds per dimension.** The checks should be quick grepping and file scanning, not deep code review. Deep dives happen in follow-up ("tell me more about X") not in the initial sweep.

### Step 4: Compile the verdict

Count PASS/WARN/FAIL, apply the verdict logic, format the output table.

### Step 5: Output

Print the table exactly as shown in the "Output format" section above. Then stop and let the user decide what to do with the findings.

**Do NOT auto-create tickets for the findings.** Offer: "Want me to create tickets for the blocking items?" — but let the user decide. The launch check is advisory.

## Rules

1. **Scannable in 10 seconds.** One table, one verdict, one blockers list. No walls of text.
2. **One row per dimension.** Details on demand, not upfront.
3. **30 seconds per dimension.** Quick grep and file scanning, not deep code review.
4. **Auto-PASS non-applicable dimensions.** A CLI doesn't need a cookie banner.
5. **Advisory, not blocking.** The user decides go/no-go based on the findings. The skill does NOT block deploys mechanically.
6. **Don't create tickets unprompted.** Offer to create them. Let the user decide.
7. **Run from the project directory.** The skill checks `workspace/<project>/`, not the ops repo.

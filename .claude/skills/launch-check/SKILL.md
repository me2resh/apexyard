---
name: launch-check
description: Production readiness audit, 10-dimension go/no-go sweep (security, a11y, compliance, analytics, SEO, GEO, perf, monitoring, docs, behaviour-quality).
disable-model-invocation: false
argument-hint: "[project-path] | trend [project-path] | --workflow [project-path]"
effort: high
---

# /launch-check: Production Readiness Audit

Read `.claude/rules/writing-standard.md`. Use the **controlled technical writing profile** for the audit
report. Lead with the verdict and next action. Keep findings below it.

Run a 10-dimension audit of a project to produce a one-page verdict. Use it at milestone boundaries: epic completion, release cuts, or launch preparation. Do not use it for each PR.

**Invoke from** the project's workspace directory (`cd workspace/<project>/`) or pass the path as an argument: `/launch-check workspace/my-app`.

## Usage

```
/launch-check                          # quick sweep of the project in the current directory
/launch-check workspace/my-app         # quick sweep of the project at this path
/launch-check trend workspace/my-app   # trend report only, no new sweep
/launch-check --workflow workspace/my-app
```

**Three modes:**

- `/launch-check [project-path]`: full audit (default). Runs all 10 dimensions **serially**. Saves results to the project history store. Renders a "Trend (last 5 runs)" section when ≥ 2 prior runs exist.
- `/launch-check trend [project-path]`: read-only trend report. Renders only the trend section from existing run files. Shows whether results improve without the audit cost. See § "Trend-only mode" below.
- `/launch-check --workflow [project-path]`: **opt-in** parallel audit with independent verification. Runs the 10 dimensions concurrently with one agent each. Independently verifies every FAIL/WARN finding before adding it to the verdict. Produces the **same** table and uses the **same** history store. It takes less time and produces fewer false positives. It costs more tokens and starts ~10–20 agents. Output and trend continuity stay the same. See § "Workflow mode" below.

## Deep-dive companions

Each dimension has an expert skill to investigate beyond the one-line summary. The launch check gives an overview. The expert skills investigate details.

| Dimension | Quick check | Deep dive |
|-----------|------------|-----------|
| Security | `/launch-check` row 1 | **`/threat-model`**: full STRIDE threat modelling exercise. Also **`/audit-deps`** for dependency findings, and **`/security-review`** when the project has an open PR |
| Accessibility | `/launch-check` row 2 | **`/accessibility-audit`**: WCAG 2.1 AA compliance audit |
| Compliance | `/launch-check` row 3 | **`/compliance-check`**: GDPR + ePrivacy analysis |
| Analytics | `/launch-check` row 4 | **`/analytics-audit`**: event taxonomy and funnel coverage |
| SEO | `/launch-check` row 5 | **`/seo-audit`**: technical SEO against Google best practices |
| Generative-engine | `/launch-check` row 6 | **`/geo-audit`**: LLM/agent discoverability (GEO + AEO), `llms.txt`, `AGENTS.md`, AI-crawler directives, JSON-LD citation grounding |
| Performance | `/launch-check` row 7 | **`/performance-audit`**: bundle, images, Core Web Vitals |
| Monitoring | `/launch-check` row 8 | **`/monitoring-audit`**: observability and incident readiness |
| Documentation | `/launch-check` row 9 | **`/docs-audit`**: Diataxis framework completeness |
| Behaviour quality | `/launch-check` row 10 | **`/mutation-test`**: Mutation-testing sensor. Measures whether the test suite constrains behaviour beyond executing lines. |

## Routing to full audits

`/launch-check` stays a quick sweep. It does not run the full audits itself.
After the table, for each WARN or FAIL row, name the matching full audit. Then ask one "Next steps" question.

- Use `AskUserQuestion` with multi-select. Make each audit its own option, with its row and status. Put the audit for the most severe row first.
- Add one separate option to create tickets for the blocking items. Add one option for "none for now".
- Without `AskUserQuestion`, print the numbered menu in § "Output format" and ask for the numbers.
- Run only the audits that the operator selects. Create tickets only when the operator selects the ticket option.
- A bare "yes" does not select anything. Ask the operator to pick the numbers.

| Row with WARN or FAIL | Full audit to name and offer |
|-----------------------|------------------------------|
| 1 Security, any finding | `/threat-model` |
| 1 Security, a dependency finding (vulnerable, outdated, or licence-flagged package from `npm audit`, `pip audit`, or similar) | `/audit-deps` |
| 1 Security, and an open PR exists for the project's current branch | `/security-review <number> <owner/repo>` |
| 2 Accessibility | `/accessibility-audit` |
| 3 Compliance | `/compliance-check` |
| 4 Analytics | `/analytics-audit` |
| 5 SEO | `/seo-audit` |
| 6 Generative-engine | `/geo-audit` |
| 7 Performance | `/performance-audit` |
| 8 Monitoring | `/monitoring-audit` |
| 9 Documentation | `/docs-audit` |
| 10 Behaviour quality | `/mutation-test` |

To find an open PR for row 1, run this lookup. Replace `<project-path>` with the project directory and `<owner/repo>` with the project's repository:

<!-- launch-check:pr-lookup (test_launch_check_pr_lookup_2028.sh runs this block) -->
```bash
branch=$(git -C "<project-path>" branch --show-current)
if [ -n "$branch" ]; then
  gh pr list --repo "<owner/repo>" --head "$branch" --state open --json number,url
else
  echo '[]'   # detached HEAD: no branch, so no PR to review
fi
```

The lookup prints a JSON list. An empty list (`[]`) means that the branch has no open PR. Offer `/security-review <number> <owner/repo>` only when the list has an entry. Always pass the repository, so the review does not resolve the number in the ops repo.
Do not offer `/security-review` when the list is empty, when the command fails, or when no `gh` installation exists. Do not use `gh pr view` with `--repo` and no PR argument. That form always fails.
A PASS row gets no offer. A row with more than one match gets every match, for example `/threat-model` and `/audit-deps`.

## Output format

The output should be **scannable in 10 seconds**. One table, one verdict, one blockers list:

```
LAUNCH CHECK: <project> @ <sha> (<date>)

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

Next steps. Pick any, for example "1 3 7", or "8" for none:
  1. Run /compliance-check     (row 3, FAIL)
  2. Run /monitoring-audit     (row 8, FAIL)
  3. Run /accessibility-audit  (row 2, WARN)
  4. Run /seo-audit            (row 5, WARN)
  5. Run /geo-audit            (row 6, WARN)
  6. Run /mutation-test        (row 10, WARN)
  7. Create tickets for the 2 blocking items
  8. None for now
```

**Do NOT print hundreds of lines.** Give each dimension ONE row in the table. Provide details in later messages only when the user requests them, for example "tell me more about the security findings".

## Verdict logic

| Condition | Verdict |
|-----------|---------|
| All dimensions PASS | **GO**: ready to launch |
| Some WARN, zero FAIL | **GO with warnings**: launch is safe. Address warnings before the next milestone |
| Any FAIL | **CONDITIONAL GO**: resolve the blocking items before launch |
| 3+ FAIL or any critical security finding | **NO-GO**: significant gaps, not launch-ready |

## The 9 dimensions

### 1. Security

**What to check:**

- Run `npm audit` / `pip audit` / equivalent for dependency vulnerabilities
- Grep for hardcoded secrets, API keys, and tokens. Use the patterns from `check-secrets.sh` against the full codebase, including unstaged files.
- Check the authentication flow. Confirm that authentication exists. Check for a reputable provider (Cognito, Auth0, Firebase Auth). Check token storage: use httpOnly cookies, not localStorage.
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
- Check color contrast: check for low-contrast color combinations in CSS/theme files
- Check keyboard navigation: are there `onClick` handlers without corresponding `onKeyDown`?
- Check for `<html lang="...">` attribute

**PASS if:** all images have alt text, semantic HTML used, no obvious contrast issues.
**WARN if:** a few missing alt texts, or minor semantic gaps.
**FAIL if:** systematic missing alt text, no semantic HTML at all, or no lang attribute.

### 3. Compliance

**What to check:**

- Check cookie consent. Search for libraries such as cookieconsent or react-cookie-consent, or a consent banner component.
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
- Check for event tracking calls, such as gtag, track, and capture.
- Check for a config file or environment variable pointing to an analytics dashboard
- Record a finding if a user-facing project has no analytics.

**PASS if:** the app configures an analytics SDK and tracks events.
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

**What to check** (quick scan, full investigation in `/geo-audit`):

- `llms.txt` and `llms-full.txt` at the site root
- `AGENTS.md` at the repo root
- AI-crawler directives in `robots.txt`, including names such as `GPTBot`, `ClaudeBot`, and `PerplexityBot`
- JSON-LD citation metadata on article-shaped pages (`author`, `dateModified`, `datePublished`, `publisher`)
- Estimate the token count of the largest docs page with `char_count / 4`. Flag pages over 25K.

This dimension covers two related areas. **GEO** concerns LLM citations from ChatGPT, Claude, Perplexity, and Gemini. **AEO** concerns coding-agent use by Claude Code, Cursor, Aider, and Cline. Both use the same artefacts, so they share one row at each milestone boundary. For the separate results in each area, run `/geo-audit`.

**PASS if:** `llms.txt` present, `AGENTS.md` present with sandbox + MCP sections, JSON-LD citation metadata on key pages.
**WARN if:** some artefacts missing (e.g. `AGENTS.md` exists but lacks sandbox links).
**FAIL if:** no `llms.txt` AND no `AGENTS.md` AND no citation JSON-LD on a content-heavy site. (Non-web projects: auto-PASS.)

### 7. Performance

**What to check:**

- If build output exists, check the bundle size. Look for `dist/`, `build/`, and `.next/`.
- Check image optimization. Check whether the app serves images as WebP/AVIF. Check for large unoptimized images (> 500KB).
- Check for lazy loading on below-the-fold images (`loading="lazy"`)
- Check for code splitting (dynamic imports, React.lazy)
- If a Lighthouse config or Web Vitals tracking exists, check the targets.

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
- If an API exists, check its documentation: an OpenAPI spec, Swagger, or doc comments.
- Deployment guide: how to deploy to staging/production
- Changelog: is there a CHANGELOG.md or are releases documented?
- Check for staleness: compare README last-modified date with recent code changes

**PASS if:** README has setup, run, and deploy instructions, and its author updated it recently.
**WARN if:** README exists but is stale (> 30 days behind code changes), or API undocumented.
**FAIL if:** no README, or README is the default GitHub template.

### 10. Behaviour quality (mutation testing)

**What to check** (quick check, full investigation in `/mutation-test`):

- Read `.claude/project-config.json → mutation.threshold` (default 60% from `.claude/project-config.defaults.json`)
- Check whether a recent mutation report exists at `projects/<name>/quality/mutation-<YYYY-MM-DD>.md` (within the last 30 days)
- If the latest report's score < threshold, report **WARN**. Do not report FAIL. Mutation predicts future quality problems but does not block launch.
- If **no recent report exists**, *offer* a fresh `/mutation-test` run. Do **NOT** run it automatically during `/launch-check`. A mutation audit takes 20–40 minutes on a medium codebase. That takes too long for an unannounced milestone audit. Report **WARN** with the finding "no recent mutation report (run `/mutation-test` for a fresh number)".
- Report **auto-PASS** if `mutation.runner` is `null`. Also report **auto-PASS** if the project has no recognised mutation runner installed for its primary language. The audit does not apply, as with SEO for non-web projects. Report the gap as `INFO` in the finding column.

**PASS if:** recent mutation report exists AND score ≥ threshold.
**WARN if:** recent mutation report exists BUT score < threshold, OR no recent report (operator should run `/mutation-test`).
**FAIL if:** never. Mutation testing is advisory and does not block launch. See AgDR-0045 for the rationale.

Report auto-PASS for projects without an installed mutation runner or a recognised language dispatch, for example Rust at v1.

## Process

### Step 1: Determine the project

If the invocation has an argument, use that path. Otherwise, use the current working directory. Verify that the path contains a git repo with source code. The launch check applies to managed projects, not the apexyard ops repo itself.

### Step 2: Quick scan

Read the project's structure to determine what checks apply:

- Is it a web app? (has `index.html`, React/Vue/Svelte/Next.js markers) → all 9 dimensions
- Is it an API only? (has routes/endpoints but no frontend) → skip accessibility, SEO, generative-engine, performance (auto-PASS)
- Is it a CLI/library? → skip accessibility, compliance, analytics, SEO, generative-engine, performance (auto-PASS on those)
- Is it a mobile app? → adjust accessibility checks for mobile, skip SEO, skip generative-engine

### Step 3: Run each applicable dimension

Check each dimension in order. For each:

1. Run the checks listed above (grep, file existence, SDK detection)
2. Classify as PASS / WARN / FAIL based on the criteria
3. Write a one-line finding for the table

**Do NOT spend more than 30 seconds per dimension.** Use quick text searches and file scans. Use the dedicated companion skills for detailed investigations, such as `/seo-audit`, `/geo-audit`, and `/threat-model`. Do not perform those investigations during the initial audit.

### Step 4: Compile the verdict

Count PASS/WARN/FAIL. Apply the verdict logic. Format the output table.

### Step 5: Output

Print the table exactly as shown in the "Output format" section above. Add the full-audit offers from § "Routing to full audits". Then continue to Step 6 to persist the run and render the trend section.

**Do NOT auto-create tickets for the findings.** The ticket option is part of the "Next steps" question in § "Routing to full audits". Create tickets only when the operator selects it. The launch check is advisory.

## Workflow mode (`--workflow`): opt-in parallel + adversarial verify

For `/launch-check --workflow [project-path]`, replace serial Steps 3–5 with one `Workflow` tool invocation. Run the 10 dimensions concurrently. Independently verify the findings. Then resume at **Step 6 (persist) unchanged**. Keep Steps 1–2 (resolve project + detect stack) and Step 6 (persist + trend) identical to the default procedure. Only the evaluation of the 10 dimensions changes from serial to parallel.

### Why a Workflow here (and why opt-in)

The 10 dimensions are **independent and read-only**. They have no shared writes, dependencies between dimensions, or human gate. Evaluate all 10 in parallel. Then use an independent skeptic to try to refute each FAIL/WARN before the verdict. This removes false positives. A workflow run starts ~10–20 agents instead of one serial pass, which costs more tokens. Therefore this mode is **opt-in**, never the default. Rationale: AgDR-0055.

**Prerequisite:** the `Workflow` tool requires explicit opt-in to multi-agent orchestration. The `--workflow` flag supplies that opt-in. When the operator passes it, author and run the workflow below. Without the flag, run the serial procedure. Do NOT invoke `Workflow`.

### The canonical workflow script

Author and run this via the `Workflow` tool. Adapt the project name and stack-skip set from Steps 1–2. Reuse the **exact PASS/WARN/FAIL criteria** from "The 9 dimensions" / row-10 below in the dimension prompts. Do not invent new criteria. Apply the existing auto-PASS rules to dimensions that do not apply. Examples include SEO/GEO/performance for non-web projects and analytics for a CLI/library. Pass these as already-resolved results instead of starting an agent.

```javascript
export const meta = {
  name: 'launch-check',
  description: 'Parallel 10-dimension production-readiness audit with adversarial verification',
  phases: [
    { title: 'Evaluate', detail: 'one agent per applicable dimension' },
    { title: 'Verify', detail: 'adversarially refute each FAIL/WARN finding' },
  ],
}

// args = { projectPath, projectName, dimensions: [{ key, label, prompt, applicable }] }
// `prompt` carries that dimension's "What to check" + PASS/WARN/FAIL criteria verbatim
// from this SKILL. Non-applicable dimensions are pre-resolved to PASS and skipped.

const DIM_SCHEMA = {
  type: 'object',
  required: ['key', 'status', 'score', 'finding'],
  properties: {
    key:     { type: 'string' },
    status:  { enum: ['PASS', 'WARN', 'FAIL'] },
    score:   { type: 'integer' },            // 0-100, same scale render-trend.sh plots
    finding: { type: 'string' },             // one-line, fits the verdict-table cell
    evidence:{ type: 'string' },             // file:line or command output backing the status
  },
}
const VERDICT_SCHEMA = {
  type: 'object',
  required: ['key', 'upheld', 'reason'],
  properties: {
    key:    { type: 'string' },
    upheld: { type: 'boolean' },             // false = the skeptic refuted the WARN/FAIL
    reason: { type: 'string' },
  },
}

const applicable = args.dimensions.filter(d => d.applicable)
const preResolved = args.dimensions.filter(d => !d.applicable)
  .map(d => ({ key: d.key, status: 'PASS', score: 100, finding: 'N/A for this project type' }))

// Phase 1+2 pipelined: each dimension verifies as soon as its evaluation returns,
// rather than waiting for the slowest dimension (no barrier).
const evaluated = await pipeline(
  applicable,
  d => agent(d.prompt, { label: `eval:${d.key}`, phase: 'Evaluate', schema: DIM_SCHEMA, agentType: d.agentType }),
  (res, d) => {
    if (!res) return null
    if (res.status === 'PASS') return res            // nothing to refute
    // Adversarially verify only WARN/FAIL: the findings that move the verdict.
    return agent(
      `Adversarially REFUTE this ${d.label} finding for ${args.projectName}: "${res.finding}" ` +
      `(evidence: ${res.evidence || 'none'}). Default upheld=false if you cannot independently confirm it. ` +
      `Re-check the codebase yourself.`,
      { label: `verify:${d.key}`, phase: 'Verify', schema: VERDICT_SCHEMA },
    ).then(v => {
      // A refuted FAIL/WARN is downgraded to PASS (the false-positive cut).
      if (v && v.upheld === false) return { ...res, status: 'PASS', finding: `${res.finding} (refuted on verify: ${v.reason})` }
      return res
    })
  },
)

return { results: [...preResolved, ...evaluated.filter(Boolean)] }
```

### After the workflow returns

1. Take `results[]` (one row per dimension, each with `status` / `score` / `finding`).
2. Count PASS/WARN/FAIL. Apply the **same verdict logic** ("Verdict logic" table above): go / go-with-warnings / conditional-go / no-go.
3. Print the **same verdict table** as the serial procedure (Step 5 "Output format"). Include the same full-audit offers (§ "Routing to full audits").
4. **Persist via Step 6 unchanged**. Build the same superset payload: `scores{}` from each row's `score`, and `findings[]` from WARN/FAIL rows. Call `audit_run_persist`. Then call `audit_render_trend`. Keep the history store, schema, and `render-trend.sh` chart identical to a serial run. This retains trend continuity across serial↔workflow runs.

### Degrade gracefully

If the `Workflow` tool is unavailable in Claude Code, state this in one line. Use serial Steps 3–5 instead. Complete the audit. `--workflow` is an optimisation, not a required dependency.

### Step 6: Persist the run + render the trend

After the verdict table, save this run to the project's history store via the shared audit-history library. Append a trend section if ≥ 2 prior runs exist.

The #218 refactor changed this step to use `_lib-audit-history.sh`. The same library supports `/threat-model`, `/security-review`, and the other audit skills. Behaviour stays the same. The JSON schema keeps the same superset structure. The library dispatches to the same `render-trend.sh` to render the chart. The trend renderer still reads adopters' existing run history at the legacy path.

#### 6a. Resolve project name + score + verdict

`<project-name>` is the project's registered name in `apexyard.projects.yaml`. If the project has no registration, use the basename of the project path. This can occur when someone runs `/launch-check` on a directory without prior onboarding. Tell the operator to run `/handover` for cross-machine trend continuity.

The headline score is the unweighted mean of `scores.*`, rounded to int. The verdict is one of `go` / `go-with-warnings` / `conditional-go` / `no-go` (launch-check-specific four-state vocabulary, preserved from the existing skill).

#### 6b. Build payload + body, persist via the lib

The library's `audit_run_persist` accepts arbitrary stdin JSON. It adds top-level `ts` / `dimension` / `verdict` / `score` fields. Then it writes a JSON file and an MD file. For launch-check, the JSON payload is a SUPERSET. It includes the legacy `scores{}` map for `render-trend.sh` to plot. It also includes a derived `findings[]` array for the canonical schema:

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
    {"id": "compliance",  "severity": "low",    "status": "open", "summary": "compliance score 76: cookie consent banner missing"},
    {"id": "performance", "severity": "medium", "status": "open", "summary": "performance score 68: bundle > 250KB"}
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

- `projects/<name>/audits/launch-check/runs/<ts>.json`: JSON with all library additions and the original payload. Library additions include top-level `ts`, `dimension: launch-check`, `verdict`, `score`, and `schema_version`. The original payload includes `scores{}`, `branch`, `commit`, `top_risks[]`, `findings[]`, and derived `stats{}`.
- `projects/<name>/audits/launch-check/<ts>.md`: frontmatter and the body above
- `projects/<name>/audits/launch-check/.gitignore`: depends on the presence of the dimension's `.audit-history-tracked` marker

**JSON schema is a SUPERSET.** The canonical fields (`ts`, `dimension`, `verdict`, `score`, `findings[]`, `stats{}`, `schema_version`) coexist with the launch-check-specific fields (`scores{}`, `branch`, `commit`, `top_risks[]`). The legacy `render-trend.sh` reads `ts` / `scores` / `verdict` and works unchanged. The new generic `audit_render_trend` reads `ts` / `score` / `verdict` and works for the rest of the audit family.

#### 6c. Render the trend section

```bash
audit_render_trend "<project-name>" "launch-check" 5
```

- The library dispatches to `render-trend.sh` for the `launch-check` dimension. Its output exactly matches the pre-#218 chart: mean of `scores.*` on the Y-axis, score-delta notes, and ASCII chart.
- The library's `audit_run_list` merges JSON from the canonical path (`projects/<name>/audits/launch-check/runs/`) and the legacy path (`projects/<name>/launch-check/runs/`). Adopters' existing history therefore continues to render across the migration. No `mv` is necessary.
- Output is a markdown trend block (heading + table + ASCII chart). Append it to this run's MD artefact and to the chat output.

#### 6d. Opt-in commit (history-tracked marker)

The per-dimension marker (`.audit-history-tracked`) is in the dimension's audit directory. It controls whether git ignores `runs/*.json` files:

```bash
# Opt in to commit launch-check history
touch projects/<name>/audits/launch-check/.audit-history-tracked
```

The library checks the marker on every save. You can change it at any time. The MD artefact at `<dim_dir>/<ts>.md` is committed regardless of the marker. It is the durable human-readable artefact.

**Migration note for adopters with existing history:** the legacy marker at `projects/<name>/launch-check/.launch-check-history-tracked` continues to apply to that path's `runs/`. To consolidate trees, create a backup first. Then run `mv projects/<name>/launch-check/* projects/<name>/audits/launch-check/`. The library's renderer reads the consolidated tree on the next run. Consolidation is optional. If you retain both trees, the library reads and merges them automatically.

## Trend-only mode: `/launch-check trend [project-path]`

This read-only mode produces only the trend section. It runs no full audit or searches for each dimension. It shows whether results improve without repeating the costly audit.

Process:

1. Source `_lib-audit-history.sh` (same as Step 6).
2. Call `audit_render_trend "<project-name>" "launch-check" 5`. The library reads both the canonical and legacy paths. If the merged set has < 2 runs, the call prints nothing. Tell the operator that no trend exists yet.
3. Print the renderer's output.

Do NOT run the 9-dimension sweep in this mode. Do NOT write any new JSON. This mode is purely for reviewing existing history.

## Rules

1. **Scannable in 10 seconds.** One table, one verdict, one blockers list. No walls of text.
2. **One row per dimension.** Details on demand, not upfront.
3. **30 seconds per dimension.** Quick grep and file scanning, not deep code review.
4. **Auto-PASS non-applicable dimensions.** A CLI does not need a cookie banner.
5. **Advisory, not blocking.** The user decides go/no-go based on the findings. The skill does NOT block deploys mechanically.
6. **Do not create tickets unprompted.** Offer them as a separate option in the "Next steps" question. Let the user decide.
7. **Run from the project directory.** The skill checks `workspace/<project>/`, not the ops repo.
8. **Persist every run via the lib.** Step 6 always calls `audit_run_persist`, regardless of opt-in commit state. The `.audit-history-tracked` marker only controls whether the JSON files are committed. The MD artefacts are committed unconditionally. The library saves every run.
9. **Resolve paths via the lib.** `audit_resolve_dir` (inside `_lib-audit-history.sh`) calls `portfolio_projects_dir` for you. The SKILL no longer needs to source the portfolio helper directly.

## Implementation notes

Persistence + trend logic ships as a shared shell helper that all audit skills consume:

| File | Purpose |
|------|---------|
| `.claude/hooks/_lib-audit-history.sh` | Audit-history library shared with /threat-model, /security-review, and other audit skills. Four functions: `audit_resolve_dir`, `audit_run_persist`, `audit_run_list`, `audit_render_trend`. |
| `render-trend.sh` (this skill's dir) | Legacy chart renderer for the launch-check dimension. The library's `audit_render_trend` dispatches to it when the dimension is `launch-check`. The chart stays identical across the #218 refactor. |

Design rationale:

- ASCII chart vs Mermaid, JSON schema choice, opt-in commit marker: see [`docs/agdr/AgDR-0014-launch-check-trend-tracking.md`](../../../docs/agdr/AgDR-0014-launch-check-trend-tracking.md)
- Audit-history lib shape, JSON+MD pair, launch-check backward-compat strategy: see [`docs/agdr/AgDR-0019-audit-artefact-persistence.md`](../../../docs/agdr/AgDR-0019-audit-artefact-persistence.md) and [`docs/technical-designs/audit-artefact-persistence.md`](../../../docs/technical-designs/audit-artefact-persistence.md)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

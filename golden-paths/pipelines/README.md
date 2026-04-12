# CI/CD Pipeline Templates

Reusable GitHub Actions workflows that integrate ApexStack's automated agents into your project builds.

## Available Pipelines

| Pipeline | Agent | Purpose | Trigger |
|----------|-------|---------|---------|
| `pr-title-check.yml` | Governance | Enforce ticket ID in PR titles | Every PR |
| `security.yml` | Shield | Security scanning (SAST, dependencies, secrets) | Every PR, push to main |
| `dependency-audit.yml` | Guardian | Dependency vulnerabilities, outdated packages, licenses | Weekly, package changes |
| `code-quality.yml` | Rex | TypeScript, ESLint, tests, build verification | Every PR |
| `review-check.yml` | Rex (verification) | Block merge if Rex hasn't reviewed the latest commit | Every PR + review event |
| `seo-check.yml` | SEO Check | SEO analysis for content files | Content changes |
| `ci.yml` | Combined | All checks in one pipeline | Every PR |

---

## Quick Start

These pipelines live inside your fork of apexstack (the ops repo) at `golden-paths/pipelines/`. To use them in a managed project, copy them into that project's own `.github/workflows/` directory.

### Option 1: Copy individual pipelines

```bash
# From your managed project's root (e.g. inside workspace/example-app/)
mkdir -p .github/workflows

# Copy specific pipelines from your ops repo
cp ~/apexstack/golden-paths/pipelines/security.yml .github/workflows/
cp ~/apexstack/golden-paths/pipelines/code-quality.yml .github/workflows/
```

(Adjust `~/apexstack` to wherever you cloned your fork.)

### Option 2: Use the combined pipeline

```bash
cp ~/apexstack/golden-paths/pipelines/ci.yml .github/workflows/
```

---

## Pipeline Details

### PR Title Check (`pr-title-check.yml`)

**Purpose**: Governance — enforce ticket tracking.

**Checks performed**:

- Validates that the PR title contains a ticket ID
- Pattern: `[A-Z]{2,5}-\d+` (project tracker) or `#\d+` (GitHub Issues)

**Fail conditions**:

- No ticket ID found in PR title

**Valid title formats**:

- `feat(ABC-123): add new feature`
- `fix(#58): correct encryption claim`
- `ABC-123: Add new feature`

---

### Security (`security.yml`)

**Agent**: Shield (Security Scanner)

**Checks performed**:

- Semgrep SAST (OWASP Top 10, security-audit rules)
- npm audit (vulnerability scanning)
- TruffleHog (secrets detection)
- CodeQL (deep analysis on main branch)
- ESLint security plugin

**Fail conditions**:

- Critical or high severity vulnerabilities
- Exposed secrets detected

**Required secrets**:

- `SEMGREP_APP_TOKEN` (optional, for Semgrep Cloud)

---

### Dependency Audit (`dependency-audit.yml`)

**Agent**: Guardian (Dependency Auditor)

**Checks performed**:

- npm audit (vulnerabilities by severity)
- npm outdated (major / minor / patch versions behind)
- license-checker (GPL, LGPL, unknown licenses)

**Automated actions**:

- Creates a GitHub issue for critical / high vulnerabilities
- Weekly scheduled audit (Monday 9 AM UTC)

**Fail conditions**:

- Critical vulnerabilities found

---

### Code Quality (`code-quality.yml`)

**Agent**: Rex (Code Reviewer)

**Checks performed**:

- TypeScript type checking (`npm run typecheck`)
- ESLint (`npm run lint`)
- Prettier formatting
- Tests (`npm run test`)
- Build verification

**Fail conditions**:

- TypeScript errors
- ESLint errors (warnings allowed)
- Test failures
- Build failures

---

### Review Check (`review-check.yml`)

**Agent**: Rex (verification)

**Purpose**: prevent merging code that was pushed *after* Rex's last review.

**Checks performed**:

- Verifies that Rex has reviewed the latest commit on the PR
- Compares commit SHAs from Rex's review against the current HEAD

**Fail conditions**:

- No Rex review found
- Rex's last review SHA does not match the current HEAD

---

### SEO Check (`seo-check.yml`)

**Pipeline**: SEO Check (no agent — pure CI workflow)

**Checks performed**:

- H1 title presence and uniqueness
- Meta description in frontmatter
- Content length (1000+ words recommended)
- Heading hierarchy (H1 → H2 → H3)
- Image alt text
- Internal links (3+ recommended)
- External links to authoritative sources

**Scores**:

| Score | Status |
|-------|--------|
| 90–100 | Excellent |
| 70–89 | Good |
| 50–69 | Needs work |
| 0–49 | Poor |

**Fail conditions**: none by default (warning only). Uncomment the threshold check to fail hard.

---

## Customisation

### Changing fail thresholds

In `security.yml`:

```yaml
env:
  FAIL_ON_SEVERITY: high  # change to: critical, high, medium, or low
```

### Adjusting schedules

In `dependency-audit.yml`:

```yaml
on:
  schedule:
    - cron: '0 9 * * 1'  # change cron expression
```

### Adding custom ESLint rules

In `code-quality.yml`, add rules to the eslint command:

```yaml
- name: Run ESLint with security plugin
  run: |
    npx eslint . --ext .ts,.tsx \
      --rule 'your-custom-rule: error'
```

---

## Required npm Scripts

Ensure your `package.json` has these scripts:

```json
{
  "scripts": {
    "typecheck": "tsc --noEmit",
    "lint": "eslint . --ext .ts,.tsx",
    "test": "vitest run",
    "build": "your-build-command"
  }
}
```

---

## Best Practices

1. **Start with `code-quality.yml`** — basic quality gates
2. **Add `security.yml` early** — catch vulnerabilities before production
3. **Enable `dependency-audit.yml`** — weekly health checks
4. **Add `review-check.yml`** — once you have agents reviewing PRs
5. **Add `seo-check.yml` for content sites** — optimise discoverability

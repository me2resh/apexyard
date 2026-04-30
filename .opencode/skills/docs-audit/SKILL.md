---
name: docs-audit
description: Documentation completeness audit using the Diataxis framework — tutorials, how-to guides, reference, explanation. Checks README quality, API docs, deployment guides, changelog, and staleness. Deep-dive companion to /launch-check's documentation dimension.
disable-model-invocation: false
argument-hint: "[project-path]"
effort: medium
---

# /docs-audit — Documentation Completeness (Diataxis)

Deep-dive documentation analysis using the Diataxis framework. Checks that docs cover all four quadrants (tutorials, how-to guides, reference, explanation) and are not stale. Invoke when `/launch-check`'s documentation row shows WARN or FAIL.

## Diataxis Framework

| Quadrant | Purpose | What to look for |
|----------|---------|-----------------|
| **Tutorials** | Learning-oriented, guided first steps | Getting started guide, quickstart, "Hello World" |
| **How-to guides** | Goal-oriented, solving specific problems | Deployment guide, migration guide, troubleshooting |
| **Reference** | Information-oriented, accurate description | API docs, config reference, CLI flags, environment variables |
| **Explanation** | Understanding-oriented, why things work | Architecture overview, design decisions (AgDRs), ADRs |

## Process

### Step 1: README quality

Check `README.md` for these sections (each is pass/fail):

| Section | Present? | Quality check |
|---------|----------|--------------|
| Project description | | One paragraph explaining what this is and who it's for |
| Prerequisites | | Language version, tools needed, accounts required |
| Quick start | | Copy-pasteable commands to get running locally in < 5 minutes |
| Development setup | | How to set up the dev environment, run tests, lint |
| Deployment | | How to deploy to staging and production |
| Contributing | | How to contribute (branch naming, PR process, code standards) |
| License | | License type and link |

### Step 2: API documentation (if applicable)

- Check for OpenAPI / Swagger spec (`openapi.yaml`, `swagger.json`)
- Check for auto-generated docs (Swagger UI, Redoc, tsdoc, typedoc)
- Check if endpoints in the code match the spec (any undocumented endpoints?)
- Check for example requests and responses

### Step 3: Operational docs

- Deployment guide: how to deploy, what environment variables are needed
- Runbook: what to do when things go wrong (overlap with `/monitoring-audit`)
- Changelog: is there a CHANGELOG.md? Are releases documented?
- Architecture overview: high-level diagram or description of components
- AgDRs/ADRs: are technical decisions documented?

### Step 4: Staleness detection

- Compare `README.md` last-modified date with recent code changes
- Check if API docs mention endpoints/features that no longer exist
- Check if environment variable docs list vars that are no longer used
- Flag docs that reference deprecated tools, libraries, or patterns

### Step 5: Output

```
DOCS AUDIT — <project> @ <sha>

Diataxis coverage:
  Tutorials:   ✓ getting-started.md exists
  How-to:      ✓ deployment guide, ✗ migration guide, ✗ troubleshooting
  Reference:   ✓ OpenAPI spec (28 endpoints), ✗ env vars undocumented
  Explanation: ✓ 3 AgDRs, ✗ no architecture overview

| # | Area | Status | Finding |
|----|------|--------|---------|
| D1 | README | WARN | Missing "Contributing" section |
| D2 | API docs | PASS | OpenAPI spec matches code (28/28 endpoints) |
| D3 | Env vars | FAIL | 12 env vars in .env.example, 0 documented in README |
| D4 | Changelog | PASS | CHANGELOG.md updated with last 5 releases |
| D5 | Staleness | WARN | README references "Express" but code migrated to Fastify 3 months ago |

Documentation readiness: PARTIAL (1 fail, 2 warnings)
```

## Rules

1. **README is the minimum.** Every project needs a README with at least: description, quick start, and how to deploy. Everything else is a "should have."
2. **Check for staleness, not just existence.** A README that exists but describes the wrong stack is worse than no README.
3. **Diataxis is a lens, not a checklist.** Don't fail a project for missing all four quadrants — most projects start with tutorials + reference and add the rest over time.
4. **Auto-PASS for the ops repo itself.** ApexYard's own docs are governed by its own process — this skill is for managed projects.

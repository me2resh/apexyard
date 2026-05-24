<!-- Source: ApexYard · templates/audits/docs-audit.md · github.com/me2resh/apexyard · MIT -->

# Documentation Audit — {project} @ {short-sha}

> Persisted by `/docs-audit` via `_lib-audit-history.sh`. Frontmatter (above) is structured; the body is freeform per dimension. See `docs/agdr/AgDR-0019-audit-artefact-persistence.md` for the schema rationale.

## Scope

Documentation completeness against the [Diataxis framework](https://diataxis.fr/) (tutorials / how-to guides / reference / explanation) plus README quality and staleness.

## Findings by Diataxis quadrant

### Tutorials (learning-oriented)

| # | Item | Status | Detail | Severity |
|---|---|---|---|---|
| D1 | "Getting started" tutorial | WARN | README has install steps but doesn't walk through a complete user flow | medium |

### How-to guides (task-oriented)

| # | Item | Status | Detail | Severity |
|---|---|---|---|---|
| D2 | Common task recipes | FAIL | No `docs/how-to/` dir; recipes live in scattered Slack threads | high |

### Reference (information-oriented)

| # | Item | Status | Detail | Severity |
|---|---|---|---|---|
| D3 | API reference | PASS | OpenAPI spec at `docs/openapi.yaml`, rendered by Swagger UI | — |
| D4 | Configuration reference | WARN | Env-var list exists but lacks default values + types | medium |

### Explanation (understanding-oriented)

| # | Item | Status | Detail | Severity |
|---|---|---|---|---|
| D5 | Architecture overview | WARN | C4 L1 + L2 diagrams exist; no narrative explaining trade-offs | medium |
| D6 | ADR / AgDR collection | PASS | 12 AgDRs in `docs/agdr/`, indexed | — |

## README quality

| # | Section | Status | Detail |
|---|---|---|---|
| R1 | What the project does | PASS | Clear one-paragraph summary |
| R2 | How to run locally | PASS | Three steps, copy-pasteable |
| R3 | How to deploy | WARN | Mentions deployment but no command reference |
| R4 | How to contribute | FAIL | No CONTRIBUTING.md |

## Staleness

Files older than 6 months that haven't been touched: `docs/architecture/c4-context.md` (12 months — likely stale post the platform migration), `README.md` § "Tech stack" (still says React 17 — actually React 18 since Q1).

## Recommended priority

1. D2 — promote the most-frequently-asked Slack recipes into `docs/how-to/`
2. R4 — minimal CONTRIBUTING.md (one page is fine; lower the barrier to first PR)
3. R3 — one-paragraph deploy reference
4. D5 — architecture-overview narrative (1-2 hours; pairs well with re-reviewing the C4 diagrams)

## Notes

(Context: doc consumers — internal team, external open-source contributors, paying customers — informs which gaps are highest-impact.)

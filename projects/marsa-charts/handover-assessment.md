# marsa-charts — Handover Assessment

**Date**: 2026-05-29
**Assessor**: Mohammad Gomaa
**Status**: handover

## Origin

- **Where it came from**: marsa-cloud org — sibling repo to `marsa` (the core PaaS); intended home for Helm charts that deploy Marsa.
- **Original owner**: marsa-cloud (Mohammed Gomaa, initial commit author)
- **Repo location**: https://github.com/marsa-cloud/marsa-charts
- **First commit date**: 2026-05-13
- **Last commit date**: 2026-05-13 (single "Initial commit")

## Current State

### Tech stack

- Language: none yet (empty repo — no source files)
- Runtime: n/a — this will be a Helm chart repo (declarative YAML, not executable code)
- Framework: Helm 3 (presumed — purpose is "Helm charts for Marsa" per repo description)
- Database: n/a
- Test framework: not configured (would expect `helm lint`, `helm unittest`, kubeval / kubeconform)
- CI: none — `.github/workflows/` absent

### Build status

- Not attempted — repo has no content beyond the initial commit (14 KB total)

### Test coverage

- Estimated: unknown (no code, no tests)

### Repo activity

- Commits in last 90 days: 1 (the initial commit)
- Open issues: 0
- Open PRs: 0
- Top contributors: Mohammed Gomaa (1 commit)

## Harnessability assessment

**Overall verdict**: `low`

> ⚠ Harnessability: LOW
>
> Rex's architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Type safety | `none` | No source files; Helm charts are declarative YAML/Go-template — no static type system. Schema-style validation (values.schema.json) is a future option. |
| Module boundaries | `flat` | No content yet. Expected eventual layout: `charts/<chart-name>/{Chart.yaml,values.yaml,templates/}` — chart-level boundaries only. |
| Framework opinionation | `weak` | Helm is a packaging tool, not a service framework — no ambient HTTP/DI/persistence conventions to lean on. |
| Test coverage signal | `absent` | No CI, no `helm lint` step, no `helm unittest` config. |
| Lint baseline | `absent` | No `.yamllint`, no chart-testing config, no `ct lint` workflow. |

The `low` verdict here is **structural** (empty repo + declarative-YAML domain), not a critique of code quality. The framework's harnessability heuristic assumes a service codebase; for a charts repo, "harness fit" is realistically capped at the `moderate` ceiling regardless of how well-tended it gets. Interpret accordingly. See AgDR-0042.

## Quality Risks

### Security

- **Empty repo, no attack surface yet** — but once charts land, watch for: hardcoded secrets in `values.yaml`, unbounded `serviceAccount` permissions, missing `securityContext` blocks, `latest` image tags, and chart-supplied default credentials.

### Dependencies

- No `Chart.yaml` dependencies yet. When subcharts are added (Postgres, Redis, ingress), pin versions and run `helm dependency update` reproducibly in CI.

### Technical debt

- **Greenfield** — no debt yet. Risk is the inverse: choices made in the first few PRs (chart structure, values schema, naming, app version vs chart version policy) will calcify quickly. Worth an early AgDR.

### Operational

- No CI → no `helm lint`, no chart-testing matrix against multiple k8s versions, no policy checks (kubeconform, conftest/OPA).
- No release automation → no chart-releaser, no published OCI/HTTP repo URL.
- No documentation → no README explaining how to install, what values are configurable, or how this maps to the `marsa` repo's deployment model.

## Integration Plan

### Roles that apply

- platform-engineer (CI, chart-releaser, repo plumbing)
- sre (production deploy readiness, observability hooks in charts)
- security-auditor (kicks in when chart templates touch RBAC / secrets / NetworkPolicies)
- tech-lead (chart structure / versioning policy decisions)

### Workflows that kick in

- [ ] PR workflow — every chart change through a PR
- [ ] AgDR for technical decisions (chart structure, versioning policy, subchart choices)
- [ ] Code Reviewer agent (Rex) on every PR — advisory-only given the `low` harnessability score
- [ ] Security Reviewer agent (Hakim) on PRs touching RBAC / secrets / SecurityContext
- [ ] `/audit-deps marsa-charts` after the first subchart lands and monthly thereafter

### Hooks to enable

- [x] `block-git-add-all` (framework-wide)
- [x] `block-main-push` (framework-wide)
- [x] `validate-branch-name` (`ticket_prefix: GH`)
- [x] `validate-pr-create`
- [x] `pre-push-gate`
- [x] `check-secrets`

(These are already on at the framework level — no per-project enabling needed.)

### CI templates to copy in (when content lands)

- [ ] `golden-paths/pipelines/security.yml` (secrets scan + dep audit — works on YAML repos too)
- [ ] `golden-paths/pipelines/pr-title-check.yml`
- [ ] A chart-specific pipeline (not shipped by the framework yet) covering `helm lint`, `ct lint`, `kubeconform`, and `helm template | conftest test`. Worth a small AgDR if/when written.

### Registry entry

Already present in `apexyard.projects.yaml`:

```yaml
- name: marsa-charts
  repo: marsa-cloud/marsa-charts
  docs: projects/marsa-charts
  status: active
  tier: P1
  roles:
    - platform-engineer
    - sre
  tags:
    - internal
    - infra
  ticket_prefix: GH
```

**Note**: status is `active` in the registry, but this assessment is the first time the project has been formally onboarded. Consider downgrading to `handover` until the first chart lands, or leaving as `active` and letting the empty-repo state speak for itself.

## Next Steps

1. ~~Decide chart structure (umbrella vs per-service)~~ → **Decided in [AgDR-0001](docs/agdr/AgDR-0001-chart-structure.md)** (tracked via [#2](https://github.com/marsa-cloud/marsa-charts/issues/2), closed)
2. ~~Set up Helm chart CI (lint, ct lint, kubeconform)~~ → Filed as [#3](https://github.com/marsa-cloud/marsa-charts/issues/3)
3. ~~Write minimum-viable README~~ → Filed as [#4](https://github.com/marsa-cloud/marsa-charts/issues/4)
4. ~~Decide chart versioning policy (independent SemVer vs lockstep with marsa)~~ → Filed as [#5](https://github.com/marsa-cloud/marsa-charts/issues/5)
5. ~~Decide chart distribution (OCI vs gh-pages)~~ → Filed as [#6](https://github.com/marsa-cloud/marsa-charts/issues/6)
6. ~~Decide subchart dependency policy (bundle vs BYO)~~ → Filed as [#7](https://github.com/marsa-cloud/marsa-charts/issues/7)

## Open Questions

- Is this repo meant to hold **one** umbrella chart for the whole Marsa platform, or a **family** of per-service charts?
- Should the chart support BYOK databases (operator-supplied connection strings) or always provision via subchart?
- Target k8s versions for the support matrix?
- Will charts publish via OCI (`ghcr.io/marsa-cloud/charts/*`) or a classic Helm HTTP repo?
- Relationship to `marsa-cloud/marsa` — does a `marsa` release tag drive a chart bump, or do they version independently?

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

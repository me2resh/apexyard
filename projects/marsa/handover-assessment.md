# marsa — Handover Assessment

**Date**: 2026-05-27
**Assessor**: Mohammad Gomaa
**Status**: handover

## Origin

- **Where it came from**: First-party project (built in-house under the marsa-cloud org)
- **Original owner**: Mohammed Gomaa (sole contributor to date)
- **Repo location**: https://github.com/marsa-cloud/marsa (local clone: `/home/gomaa-zorin/Github/marsa-workspace/marsa`)
- **First commit date**: 2026-05-12
- **Last commit date**: 2026-05-27 (active today)

> Note: `marsa` was already listed in `apexyard.projects.yaml` (P0, core, customer-facing). This is a **re-handover** that produces the first metadata-derived assessment + architecture stub. The registry entry pre-dates this doc.

## Current State

### Tech stack
- **Repo shape**: pnpm monorepo (`pnpm@9.15.0`), workspaces `apps/*` + `packages/*`, shared dependency `catalog:` in `pnpm-workspace.yaml`
- **Language**: TypeScript (`^5.7.3`), Node `>=22`, ESM (`"type": "module"`, `module: nodenext`)
- **API** (`apps/api`): NestJS 11 (Fastify + Express platforms), MikroORM 6 (PostgreSQL), `pg` driver, Swagger/OpenAPI generation. Tests via node's built-in test runner (`node --test`) + sinon + supertest + expect.
- **Web** (`apps/web`): Nuxt 4 + Vue, Nuxt UI, Tailwind 4, Zod. Tests via Vitest + `@vue/test-utils` + happy-dom; E2E via Playwright.
- **Web ↔ API contract**: `@hey-api/openapi-ts` generates the web client from the API's OpenAPI spec — typed contract between the two apps.
- **Database**: PostgreSQL 17 (via `docker-compose.yml`, MikroORM migrations)
- **CI**: GitHub Actions — `ci.yml` (push/PR to main), `cd.yml` (deploy on main + version tags), `claude.yml` (Claude Code on issues/PR comments)
- **License**: AGPL-3.0

### Build status
- `pnpm install`: not attempted (operator chose skip — repo is active and CI is green on main)
- `pnpm build`: not attempted
- `pnpm test`: not attempted
- `pnpm lint`: not attempted

### Test coverage
- Estimated: unknown. `@vitest/coverage-v8` is installed for web, but no coverage **threshold** is configured in any vitest/test config. The API uses node's test runner with no coverage gate. No coverage step found in CI.

### Repo activity
- Commits in last 90 days: 78 (repo is ~2 weeks old — high velocity)
- Open issues: 15+ (active backlog — V0.1 milestones for Auth, Networking, Deployment, Helm chart, etc.)
- Open PRs: 0 (latest merged: #33 `feat/11-communication-between-api-and-web`)
- Top contributors: Mohammed Gomaa (sole author)

## Harnessability assessment

**Overall verdict**: `moderate`

3 of 5 dimensions land in the top bucket (module boundaries, framework opinionation, lint baseline). The two gaps — partial type-safety strictness and no coverage threshold — are easy follow-ups, not structural problems. Rex's architecture handbooks (including blocking ones) will mostly fire accurately; expect occasional noise from the `strictNullChecks`-only TS config until full `strict` is enabled.

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Type safety | `partial` | `tsconfig.base.json` sets `strictNullChecks: true` only — not full `strict`; `apps/api/tsconfig.json` disables `strictBindCallApply`; `apps/web` relies on Nuxt-generated tsconfig (no explicit strict line) |
| Module boundaries | `strong` | pnpm monorepo with `apps/*` + `packages/*` workspaces (`pnpm-workspace.yaml`) → package-level boundaries; NestJS module structure in `apps/api` |
| Framework opinionation | `strong` | `apps/api` is NestJS 11 (DI + HTTP + MikroORM persistence — full opinionation); `apps/web` is Nuxt 4 |
| Test coverage signal | `absent` | `@vitest/coverage-v8` installed but no `coverage.thresholds` in any vitest config; API uses `node --test` with no coverage gate; no coverage step in `ci.yml` |
| Lint baseline | `present` | `eslint.config.mjs` (ESLint 9 flat config) at repo root + per-app `lint` scripts; Prettier configured |

See AgDR-0042 for the scoring rationale and v1 thresholds.

## Quality Risks

### Security
- **`apps/api/.env.test` is tracked in git** — contains test environment configuration (not read per handover policy). Test creds in a repo are lower-risk than prod secrets, but worth confirming no real credentials leak via the test env. The real `apps/api/.env` is correctly gitignored. ✓
- Auth is not yet implemented — issues #22 (Marsa Auth), #23 (GitHub Auth), #27 (Auth V0.1) are open. Auth/crypto code will need the Security Auditor on first implementation PR.

### Dependencies
- Young repo on current major versions (NestJS 11, Nuxt 4, MikroORM 6, ESLint 9, Vitest 3) — no obvious staleness. Run `/audit-deps` to confirm no transitive CVEs.

### Technical debt
- **No coverage threshold** — coverage tooling installed but no gate. Easy to under-test as the codebase grows.
- **Partial TS strictness** — `strictNullChecks` only; full `strict` not enabled across the monorepo.

### Operational
- CD pipeline exists (`cd.yml`) but the product's own deployment target (K3s / Helm) is still being built — see issues #21 (Deployment Pipeline), #26, #30 (first Helm chart). No production observability evidence found (no Sentry/Datadog/OpenTelemetry deps).

## Integration Plan

### Roles that apply
- `tech-lead` (always)
- `backend-engineer` (NestJS API)
- `frontend-engineer` (Nuxt web)
- `qa-engineer` (acceptance verification — no coverage gate yet)
- `platform-engineer` (CI/CD: ci.yml, cd.yml)
- `sre` (deployment target is Kubernetes; CD pipeline + Helm work in flight)
- `security-auditor` (conditional — activates on the upcoming Auth PRs #22/#23/#27)

### Workflows that kick in
- [ ] PR workflow (`.claude/rules/pr-workflow.md`) — every change through a PR
- [ ] AgDR for technical decisions
- [ ] Code Reviewer agent (Rex) on every PR
- [ ] Security Reviewer agent (Hakim) on first pass + auth PRs
- [ ] `/audit-deps marsa` on adoption and monthly thereafter

### Hooks to enable
- [ ] `block-git-add-all`
- [ ] `block-main-push`
- [ ] `validate-branch-name` (ticket_prefix `GH` per registry)
- [ ] `validate-pr-create`
- [ ] `pre-push-gate`
- [ ] `check-secrets`

### CI templates to copy in
The repo already has `ci.yml` + `cd.yml`. Compare against `golden-paths/pipelines/` and consider adding:
- [ ] `security.yml` (Semgrep + npm/pnpm audit + secrets detection) — not currently present
- [ ] coverage reporting step in `ci.yml`

### Registry entry

`marsa` is already registered. The existing entry already carries the right roles. During this handover the local clone was **moved** from its sibling location (`../marsa`) into `workspace/marsa` inside the ops repo, and the registry entry now records `workspace: workspace/marsa`. Portfolio skills (`/status`, `/projects`, LSP-aware deep-dives) will treat `marsa` as cloned. `workspace/*/` is gitignored, so the clone does not pollute the ops fork.

## Next Steps

1. Set up a test coverage threshold (vitest `coverage.thresholds` for web + a coverage gate for the API's `node --test` run) before the backlog grows further
2. Enable full TypeScript `strict` mode in `tsconfig.base.json` (currently `strictNullChecks` only) to maximise harness signal quality
3. /audit-deps marsa — confirm no transitive CVEs across the NestJS + Nuxt dependency tree
4. Add a `security.yml` CI pipeline (Semgrep + pnpm audit + secrets detection) — not currently present
5. Confirm `apps/api/.env.test` carries no real credentials (it's tracked in git)
6. Triage the 15+ open issue backlog (V0.1 milestones) to confirm priority order before the next sprint
7. /code-review the most-recent merged PR (#33) as Rex to calibrate review standards against marsa's conventions

## Post-Handover Checklist

- [ ] Review this assessment (sole owner is also the operator — mostly a self-check)
- [ ] Add a coverage threshold + gate — close before the first feature PR
- [ ] Enable full TS `strict` — scheduled in the first 2 weeks
- [ ] Confirm `apps/api/.env.test` has no real secrets
- [ ] `marsa` is already in the weekly `/stakeholder-update` rollup (P0 core project)
- [ ] Run `/audit-deps marsa` monthly for the next 3 months
- [ ] Set up a coverage baseline and commit the threshold

## Open Questions

- Is the Kubernetes/K3s deployment target in-repo (Helm chart issues open) or split into `marsa-charts`? (Registry lists `marsa-charts` separately — confirm the boundary.)
- What's the intended auth approach (GitHub OAuth per #23, or broader)? Affects when the Security Auditor activates.
- Is there a target coverage % for V0.1, or is coverage intentionally deferred until post-MVP?

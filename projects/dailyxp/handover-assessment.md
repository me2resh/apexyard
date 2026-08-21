# dailyxp — Handover Assessment

**Date**: 2026-08-21
**Assessor**: MohamedKH (vincentvan205ater@gmail.com)
**Status**: handover

## Origin

- **Where it came from**: Solo-authored Omarchy-first product (Mohamed Osama Mohamed Khater)
- **Original owner**: da5ater / MohamedKH
- **Repo location**: `https://github.com/da5ater/dailyxp.git` (local path: `/run/media/mohamed/storage/Projects/DailyXP`)
- **First commit date**: 2026-08-20 16:39:39 +0300 — `Initialize DailyXP planning contract`
- **Last commit date**: 2026-08-21 20:08:06 +0300 — `fix: bar widget – revert invalid onReleased, keep original press handler`

## Current State

### Tech stack

- **Language**: JavaScript (Qt-free domain models) + QML (Omarchy Quattro shell plugin host)
- **Runtime**: Omarchy 4 / Quattro shell plugin host (headless QML service `StateStore.qml`, bar widget `BarWidget.qml`, panel `Panel.qml`); no external daemon, installer, or second Quickshell process
- **Framework**: Omarchy plugin SDK (`manifest.json` kind `bar-widget` + `service`); no npm/pip/cargo/go package manager — domain models are plain JS modules
- **Database**: Local-only durable state: checksum-protected primary/backup envelope under `$XDG_STATE_HOME/dailyxp/` with a canonical versioned event journal (`EventModel.js`); hosted Rails/PostgreSQL service is planned (portable, not yet present in repo)
- **Test framework**: `node --test` (Node built-in), 16 test files covering every domain model
- **CI**: None detected — no `.github/workflows/`, no `.gitlab-ci.yml`, no Dockerfile / docker-compose

### Build status

- `node --test tests/*.test.js`: **ok — 137/137 pass** (duration ~143 ms, verified 2026-08-21)
- `qmllint -I /usr/share/omarchy/shell BarWidget.qml Panel.qml StateStore.qml`: **ok with expected Omarchy-import warnings** — `qs.Commons` / `qs.Ui` and `WidgetButton` unresolved outside an Omarchy shell checkout, no syntax errors
- `npm install` / `npm run build` / `npm run lint`: **n/a** — no `package.json`; no lint or build pipeline present

### Test coverage

- Estimated: **unknown** — no coverage threshold or coverage step configured; tests exist and are green but no `coverageThreshold`, `.nycrc`, or CI coverage gate to quantify
- Raw volume: 16 test suites (event, feed, habit, insight, planning, progression, recovery, session, share, state, story, ux, plus journal and store helpers)

### Repo activity

- **Commits in last 90 days**: 64 (100% of history; repo is 1 day old)
- **Commits total**: 64 (linear history, 5 merge PRs)
- **Open issues**: 1 — `#13 [COLD] Re-audit AWS and home-server hosting on 2026-10-20` (labels: `ready-for-human`, `cold`; deferred checkpoint)
- **Open PRs**: 0
- **Top contributors**: Single author (MohamedKH); `shortlog` empty (no `user.name` attribution on commits beyond the single git identity)
- **Branch**: `main` (default), no stale feature branches observed

## Harnessability assessment

**Overall verdict**: `low`

> ⚠ Harnessability: LOW
>
> Rex's architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Type safety | `none` | No `tsconfig.json`, no `sorbet/` sigils, no `mypy.ini` / `[tool.mypy]` / `pyrightconfig.json`; models are plain JS with runtime validation only (e.g. `EventModel.js` line 7: `UUID_V4_PATTERN` regex guard, not a type system) |
| Module boundaries | `flat` | No `src/domain/` / `src/application/` / `src/infrastructure/` dirs; flat repo root with `*Model.js` + `*Journal.js` + 3 QML files; no `packwerk.yml` / workspace monorepo config |
| Framework opinionation | `weak` | No `package.json` deps; no Next.js/NestJS/FastAPI/Django/Rails/Go framework present in the repo tree; runtime is the external Omarchy shell plugin host (opinionated at deploy, not at build — not in the harness's framework table) |
| Test coverage signal | `absent` | No `coverageThreshold` in any config, no `--cov` / `[tool.coverage]` / `vitest coverage.thresholds`; no coverage step in CI (no CI at all) |
| Lint baseline | `absent` | No `.eslintrc.*` / `eslint.config.*`, no `.rubocop.yml` / `.golangci.yml` / `ruff` / `.pre-commit-config.yaml`; `qmllint` is documented in `README.md` Verify but not enforced by config or CI |

See AgDR-0042 for the scoring rationale and v1 thresholds.

## Quality Risks

### Security

- **No hardcoded secrets found in the static scan** — `.env` / `.env.example` absent; `grep` for `api_key/password/secret/token` hit only generic validation regexes in `EventModel.js`, not credential literals
- **No auth surface yet** — local-only product; Rails API not present to audit; revisit when `da5ater/dailyxp` gains a hosted service
- **Local data sensitivity acknowledged** — `Recovery Track` / `Recovery Circle` are privacy-sensitive; data lives under `$XDG_STATE_HOME/dailyxp/` with no network exfiltration path today; future sync must preserve the "sensitive by design" invariant (PRD non-goal: no diagnosis/treatment, no contact uploads)

### Dependencies

- **Zero package-manager dependencies** — no `package.json` / `pyproject.toml` / `Cargo.toml` / `go.mod` / `Gemfile`; nothing to audit for CVEs. Risk is inverted: no lockfile also means no Dependabot surface until the Rails service lands
- **System deps are external**: `mkdir`/`readlink` (coreutils), `notify-send`, Omarchy shell, `/etc/localtime` symlink — all out-of-repo; no vendored binaries

### Technical debt

- **No type system** — every model is untyped JS; `EventModel.js` compensates with exhaustive runtime guards (IANA zone regex, UTC instant round-trip, `Object.isFrozen`), but Rex's clean-architecture handbooks will treat this as advisory-only
- **No lint / format baseline** — `qmllint` is the only checker, and it requires an Omarchy checkout to resolve `qs.*` imports; JS has no ESLint/Ruff baseline
- **Flat module layout** — 16 JS models + 3 QML views co-located at root; no `domain/` / `application/` / `infrastructure/` seam, so layering violations are invisible to handbooks
- **No CI** — green local tests (137/137) are not gated on push/PR; regressions have no mechanical backstop

### Operational

- **No CI, no deploy automation, no monitoring** — README documents `omarchy plugin validate` + `omarchy-shell` probes, but there is no GitHub Actions pipeline, no Sentry/Datadog/CloudWatch, no health endpoint, no deploy runbook
- **Offline-only today is a strength** — but the PRD's "cheapest efficient design" principle and the `aws-zero-spend.md` wayfinder note imply a future AWS-or-home-server Rails host that is not yet wired to this repo

## Integration Plan

### Roles that apply

- `tech-lead` — always (owns the planning/product-to-engineering seam; `docs/design/dailyxp-v1.md` is 1036 lines)
- `backend-engineer` — the JS domain models (`EventModel`, `PlanningModel`, `SessionModel`, etc.) and the future Rails API
- `frontend-engineer` — `BarWidget.qml` / `Panel.qml` / `StateStore.qml` (QML UI + animated transitions)
- `sre` — future Rails/PostgreSQL host (PRD non-goal acknowledges single-AZ fragility; deferred via issue #13)

`platform-engineer` and `security-auditor` are not seeded initially — no CI to own yet and no auth/crypto surface to audit; they wire in when CI lands and the Rails service appears.

### Workflows that kick in

- [ ] PR workflow (`.claude/rules/pr-workflow.md`) — every change through a PR (repo already follows this: 5 merged PRs)
- [ ] AgDR for technical decisions (notably the upcoming Rails/AWS-vs-home-server call on 2026-10-20)
- [ ] Code Reviewer agent (Rex) on every PR — advisory-only until harnessability scaffolding lands
- [ ] Security Reviewer on the first hosted-service PR
- [ ] `/audit-deps` once a package manager appears (currently n/a)

### Hooks to enable

- [ ] `block-git-add-all`
- [ ] `block-main-push`
- [ ] `validate-branch-name` (set `ticket_prefix` for `da5ater/dailyxp` issues)
- [ ] `validate-pr-create`
- [ ] `pre-push-gate` (wire `node --test` + `qmllint` as the local gate)
- [ ] `check-secrets`

### CI templates to copy in

- [ ] `golden-paths/pipelines/ci.yml` — adapt to `node --test` + `qmllint` (not the default TS/Next lint/typecheck/test/build)
- [ ] `golden-paths/pipelines/security.yml` — semgrep + secrets scan once the Rails surface appears
- [ ] `golden-paths/pipelines/pr-title-check.yml` — already matches the existing `feat/chore/fix` commit style

### Registry entry

The entry that will be appended to `apexyard.projects.yaml` at the root of the ops repo (see registry step — the skill does this append for you, with confirmation):

```yaml
- name: dailyxp
  repo: da5ater/dailyxp
  workspace: workspace/dailyxp
  docs: projects/dailyxp
  status: handover
  roles:
    - tech-lead
    - backend-engineer
    - frontend-engineer
    - sre
```

## Next Steps

Derived from the Quality Risks above — each maps to a specific finding, not a generic placeholder.

1. Set up test coverage reporting (`node --test` has no threshold; add a coverage gate before the first post-handover feature so a future regression is caught) — before the first feature PR
2. Re-enable CI on this repo — copy and adapt `golden-paths/pipelines/ci.yml` to run `node --test` + `qmllint` on every PR; baseline must be green before new features
3. Decide observability for the future Rails host (`/decide` on error tracking / health endpoint / alerting — Sentry vs CloudWatch vs self-hosted) before the first deploy
4. Calibrate Rex on this codebase — `/code-review` the most-recent merged PR as Rex to tune the advisory-only signal on a flat JS/QML layout
5. Add `dailyxp` to the weekly `/stakeholder-update` rollup once CI is live

## Cleanup (REQUIRED before exit)

```bash
rm -f .claude/session/active-bootstrap
```

Always remove the bootstrap marker on a clean exit. If the skill is interrupted before this step, `clear-bootstrap-marker.sh` clears the stale marker on the next session.

## Post-Handover Checklist

- [ ] Review this assessment with Mohamed (single-owner repo — context the static read couldn't surface)
- [ ] Coverage + CI (items 1–2 above) — close before the first feature PR
- [ ] Observability decision (item 3) — schedule before the first Rails deploy
- [ ] Add `dailyxp` to the weekly `/stakeholder-update` rollup
- [ ] Onboard `tech-lead` / `backend-engineer` / `frontend-engineer` / `sre` into the review rotation when the Rails surface appears
- [ ] Set up a coverage baseline (run `node --test` with a coverage reporter and commit the threshold)
- [ ] Run `/audit-deps dailyxp` monthly once a package manager appears (currently n/a)

## Open Questions

- Future Rails/PostgreSQL service: where will it live (AWS vs home server)? Issue #13 already checkpoints this on 2026-10-20 — PRD prefers cheapest efficient design with a zero-cost local-dev path
- QML lint baseline: `qmllint` requires an Omarchy checkout (`/usr/share/omarchy/shell`); CI will need either a checkout step or a tolerant `qmllint` invocation that ignores `qs.*` imports
- Domain doc authority: `CONTEXT.md` is the single-context glossary; `AGENTS.md` routes Wayfinder questions to chat with Mohamed — how does this compose with ApexYard's product-manager / tech-lead roles on future feature PRDs?

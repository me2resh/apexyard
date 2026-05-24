---
name: handover
description: Onboard an external repo via a structured handover assessment + harnessability scoring across 5 codebase dimensions.
argument-hint: "<project name> [path or url] [--topology <name>]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /handover — External Repo Handover Assessment

Adopt an external repo into ApexYard management. The skill reads the target repo, synthesises a structured handover document, and tells you which ApexYard roles, workflows, and hooks should kick in.

This is the bridge between "we just inherited this codebase" and "this codebase is now governed by our normal SDLC".

## LSP-aware (optional, recommended)

The handover deep-dive — reading the codebase to populate the assessment — performs semantic code navigation: finding definitions, walking references, tracing handlers across modules. With LSP enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`) **and** the repo cloned locally (see the clone-first prompt from me2resh/apexyard#188), queries are ~3-15× cheaper in token cost than grep + Read on shallow lookups, and ~1.4-5× cheaper on multi-hop traces. Without LSP — or when only metadata is available — the skill falls back to grep + Read transparently. No new failure mode, just optional speed during the deep-dive phase.

Per-language LSP plugins live in Claude Code's marketplace. Install once; the skill detects the active language and dispatches automatically.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/handover legacy-billing-api
/handover legacy-billing-api ../legacy-billing-api
/handover marketing-site https://github.com/some-org/marketing-site
/handover marketing-site --topology typescript-nextjs
```

The `--topology <name>` flag pre-selects a topology bundle and skips the interactive pick in step 1.5. Available v1 topologies: `typescript-nextjs`, `python-fastapi`, `go-data-pipeline`. See [`topologies/README.md`](../../../topologies/README.md) and AgDR-0048.

## Output location

The skill writes two files under `projects/<name>/`:

```
projects/<name>/handover-assessment.md         ← always (re)written
projects/<name>/architecture/container.md      ← only if missing — stub L2 C4 diagram
```

The folder lives in the ops repo (your fork of apexyard), alongside the rest of `projects/`.

If `projects/<name>/` doesn't exist, create it. Also seed a `projects/<name>/README.md` stub if missing — see `projects/README.md` for the convention.

The architecture stub is **written once** and never overwritten — it's a starting point, not a generated artefact. After the first handover, any edits the team makes to refine the diagram survive re-runs of the skill.

## Process

### 0. Mark this session as bootstrap (REQUIRED)

`/handover` may run before any tracker tickets exist for the project being adopted, so the `require-active-ticket.sh` PreToolUse hook would block the registry / `projects/<name>/` writes the skill needs. Write a marker so the hook exempts this skill (it's on the default `bootstrap_skills` list in `.claude/project-config.defaults.json`):

```bash
mkdir -p .claude/session && echo "handover" > .claude/session/active-bootstrap
```

Clear the marker on completion (Step "Post-Handover Checklist" below). If the skill is interrupted, the SessionStart hook `clear-bootstrap-marker.sh` clears it at the start of the next session. See AgDR-0011 + me2resh/apexyard#150.

### 1. Locate the target repo

If a path is given, use it. If a URL is given, prompt the user to clone it into `workspace/<name>/` first (don't clone automatically — that's a side-effect with cost). If nothing is given, ask:

```
Where is the target repo? Local path or git URL?
```

### 1.5. Pick a topology (default: skip / custom)

ApexYard ships **harness-template topologies** — bundles of curated handbooks + CI pipelines + AgDR templates per service shape. Picking one here pre-bakes the right governance surface for the stack; declining keeps the existing flow byte-for-byte. See [`topologies/README.md`](../../../topologies/README.md) and AgDR-0048.

If the operator passed `--topology <name>` on the CLI, skip the interactive prompt and use that pick. Otherwise prompt:

```
Which topology fits this project?

  [1] typescript-nextjs   — TypeScript + Next.js web app (App Router, Prisma, JWT)
  [2] python-fastapi      — Python + FastAPI service (Pydantic v2, SQLAlchemy async, JWT)
  [3] go-data-pipeline    — Go batch / streaming pipeline (no HTTP surface)
  [4] Skip / custom       — no topology bundle; use the framework defaults

Read topologies/<name>/README.md for what each bundle includes.

[1/2/3/4 — default 4]
```

**Branching:**

- **Pick 1/2/3:** record the topology name in `$PICKED_TOPOLOGY` (e.g. `typescript-nextjs`). Verify the topology dir exists at `<ops_root>/topologies/<name>/`. If missing (e.g. operator on an older framework version), print `⚠ topology dir not found — falling back to no bundle` and continue with `$PICKED_TOPOLOGY=""`.
- **Pick 4 / default / any other input:** set `$PICKED_TOPOLOGY=""`. Continue exactly as the pre-topology flow.

**Verifying the pick.** Read the topology's `README.md` and `VERSION` files. Print a one-line confirmation:

```
Topology: typescript-nextjs v1.0.0 — will instantiate 11 files into projects/<name>/ and workspace/<name>/.github/workflows/. (See step 5.5.)
```

If `$PICKED_TOPOLOGY=""`, print nothing — the rest of the flow is unchanged.

### 2. Read the surface area

Without running anything destructive, gather:

```bash
# Tree (top 2 levels, prune node_modules / .git)
find <repo> -maxdepth 2 -type d \
  ! -path '*/node_modules*' \
  ! -path '*/.git*' \
  ! -path '*/dist*' \
  ! -path '*/build*'

# Key files
ls <repo>/README* <repo>/package.json <repo>/pyproject.toml \
   <repo>/Cargo.toml <repo>/go.mod <repo>/Gemfile 2>/dev/null

# CI config
ls <repo>/.github/workflows/ 2>/dev/null

# Last commit & contributors
git -C <repo> log -1 --format='%h %ai %an %s'
git -C <repo> shortlog -sn --no-merges | head -10

# Open issues / PRs (if it's a GitHub repo)
gh -R <owner/name> issue list --state open --json number,title,labels --limit 10
gh -R <owner/name> pr list --state open --json number,title --limit 10
```

### 3. Detect the tech stack

Look at:

- `package.json` → Node ecosystem; check `engines`, `scripts`, `dependencies`
- `pyproject.toml` / `requirements.txt` → Python
- `Cargo.toml` → Rust
- `go.mod` → Go
- `Gemfile` → Ruby
- `Dockerfile` → containerised; what base image?
- `.github/workflows/` → existing CI; how mature?
- `tsconfig.json` strictness, presence of tests, presence of linters

### 4. Try a build (optional, ask first)

```
Should I attempt to build the project to check current health? (y/n)
```

If yes and it's a Node project: `npm install --ignore-scripts && npm run build` (or whatever the package.json scripts say). Capture pass/fail and any errors.

### 4.5. Harnessability assessment

> Why this exists. ApexYard's value as a "harness" depends on the codebase having the ambient affordances the framework's rules and handbooks expect — type safety, module boundaries, lint baselines, etc. When those are missing, Rex's architecture handbooks (especially `ENFORCEMENT: blocking` ones like clean-architecture-layers) fire false positives and create review noise rather than catching real issues. Naming that gap during adoption — rather than after the first noisy code review — gives the operator a chance to either adopt advisory-only, or schedule the scaffolding work as a follow-up. This step codifies the assessment so a `low` score becomes a visible warning at adoption time, not a surprise.
>
> The framing draws on industry-standard harness-engineering prior art on **ambient affordances** — the idea that a tool's effectiveness depends on the working environment already supplying the signals the tool relies on. See AgDR-0042.

Score 5 codebase dimensions, each with a 1-line rationale citing the evidence found in steps 2-4. Combine into an overall verdict (high / moderate / low) using the truth table below. If `low`, print the warning text verbatim. Persist the result in the handover assessment file (step 5).

#### The 5 dimensions

| # | Dimension | What to check (examples per language) | Verdict |
|---|-----------|----------------------------------------|---------|
| 1 | **Type safety** | TS: `tsconfig.json` with `"strict": true` (or all `strict*` flags set). Ruby: `sorbet/` dir + `# typed:` sigils in src files. Python: `mypy.ini` OR `[tool.mypy] strict = true` in `pyproject.toml` OR `pyrightconfig.json` strict. Go: implicitly strong (assume `strong`). Rust: implicitly strong (assume `strong`). | `strong` / `partial` / `none` |
| 2 | **Module boundaries** | Presence of `src/domain/` + `src/application/` + `src/infrastructure/` (clean-architecture); presence of `packwerk.yml` + `packs/` (Ruby Packwerk); monorepo workspace config (`package.json` `workspaces:`, `pnpm-workspace.yaml`, `nx.json`, `turbo.json`) indicating package-level boundaries. Otherwise flat single-`src/`. | `strong` / `partial` / `flat` |
| 3 | **Framework opinionation** | `package.json` deps containing Next.js / NestJS / Remix (TS strong); `pom.xml` / `build.gradle` containing Spring (Java strong); `requirements.txt` / `pyproject.toml` containing Django / FastAPI (Python strong / moderate respectively); `Gemfile` containing Rails (Ruby strong); `go.mod` containing Gin / Echo (Go moderate) vs raw `net/http` only (weak). Strong = full opinionation (persistence + HTTP + DI / conventions). Moderate = HTTP framework only. Weak = raw scripts, no framework. | `strong` / `moderate` / `weak` |
| 4 | **Test coverage signal** | `jest.config.*` with a `coverageThreshold` block; `.nycrc` (Istanbul) with thresholds; `pytest.ini` / `setup.cfg` / `pyproject.toml` containing `--cov` or `[tool.coverage]`; `vitest.config.*` with `coverage.thresholds`; Go CI step running `go test -cover`; coverage step / threshold in any `.github/workflows/*.yml` or `.gitlab-ci.yml`. | `present` / `absent` |
| 5 | **Lint baseline** | ESLint config (`.eslintrc.*`, `eslint.config.*`); RuboCop (`.rubocop.yml`); golangci-lint (`.golangci.yml`); ruff / flake8 / pylint config (or `[tool.ruff]` etc. in `pyproject.toml`); `.pre-commit-config.yaml` with any linter hook. | `present` / `absent` |

Each dimension MUST be backed by a one-line rationale citing the evidence path and key signal, e.g.:

```
- Type safety: strong — tsconfig.json line 6: "strict": true
- Module boundaries: flat — only src/, no domain/application/infrastructure dirs
- Framework opinionation: moderate — package.json has express but no ORM/DI framework
- Test coverage signal: absent — no coverageThreshold in jest.config.js, no coverage step in .github/workflows/
- Lint baseline: present — .eslintrc.json at repo root
```

#### Overall verdict (truth table)

Count how many of the 5 dimensions are `strong` or `present` (the "good" buckets):

| Strong-or-present count | Other conditions | Verdict |
|-------------------------|------------------|---------|
| 5 / 5 | — | `high` |
| 3 or 4 / 5 | — | `moderate` |
| ≤ 2 / 5 | — | `low` |
| any | Type safety is `none` AND framework opinionation is `weak` | `low` (override — these two together amplify each other) |

Implement the rule as a bash-shaped truth table so re-implementations agree:

```bash
# Pseudocode — dimension verdicts as variables
# Each is one of: strong/partial/none, strong/partial/flat,
#                 strong/moderate/weak, present/absent, present/absent
good=0
[ "$type_safety"        = "strong"  ] && good=$((good+1))
[ "$module_boundaries"  = "strong"  ] && good=$((good+1))
[ "$framework_opinion"  = "strong"  ] && good=$((good+1))
[ "$test_coverage"      = "present" ] && good=$((good+1))
[ "$lint_baseline"      = "present" ] && good=$((good+1))

if [ "$type_safety" = "none" ] && [ "$framework_opinion" = "weak" ]; then
  verdict="low"
elif [ "$good" -ge 5 ]; then
  verdict="high"
elif [ "$good" -ge 3 ]; then
  verdict="moderate"
else
  verdict="low"
fi
```

These thresholds are deliberately conservative for v1 — `high` requires every dimension to be in the top bucket. See AgDR-0042 for the rationale and tuning notes.

#### Warning text (only when verdict is `low`)

Print this text **verbatim** to the operator after the assessment, and also embed it inside the handover-assessment.md file under the "Harnessability assessment" section:

```
⚠ Harnessability: LOW

Rex's architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)
```

For `high` and `moderate` verdicts, do NOT print the warning — the score in the assessment file is enough.

#### What this step does NOT do

- Does **not** auto-fix the missing scaffolding. Adding TS strict, ESLint, coverage thresholds, etc. is out of scope and must be filed as a follow-up by the operator.
- Does **not** apply per-team / per-stack weights to the dimensions. v1 is universal; per-team tuning is deferred.
- Does **not** track the score over time. The score lives in the handover-assessment.md only; re-running `/handover` re-scores from the live tree.

See AgDR-0042 for the dimensions + thresholds rationale, the alternatives considered, and the legacy-adopter sensitivity.

### 5. Synthesise the assessment

Write `projects/<name>/handover-assessment.md`:

````markdown
# {name} — Handover Assessment

**Date**: YYYY-MM-DD
**Assessor**: {git user}
**Status**: handover

## Origin

- **Where it came from**: {acquisition / inherited team / open source / contractor / etc.}
- **Original owner**: {if known}
- **Repo location**: {URL or path}
- **First commit date**: {from git log}
- **Last commit date**: {from git log}

## Current State

### Tech stack
- Language: {…}
- Runtime: {…}
- Framework: {…}
- Database: {…}
- Test framework: {…}
- CI: {…}

### Build status
- `npm install`: {ok / failed}
- `npm run build`: {ok / failed / not attempted}
- `npm run test`: {ok / failed / not attempted}
- `npm run lint`: {ok / failed / not attempted}

### Test coverage
- Estimated: {…} (from coverage report if available, otherwise "unknown")

### Repo activity
- Commits in last 90 days: {…}
- Open issues: {…}
- Open PRs: {…}
- Top contributors: {…}

## Harnessability assessment

**Overall verdict**: `{high | moderate | low}`

{If `low`, embed the warning block verbatim here:}

> ⚠ Harnessability: LOW
>
> Rex's architecture handbooks will fire advisory-only on this codebase. The blocking gate (`ENFORCEMENT: blocking`) will generate false positives. Recommended: adopt as advisory-only, plan a follow-up to add the missing scaffolding (typescript strict, lint baseline, etc.)

| Dimension | Score | Evidence |
|-----------|-------|----------|
| Type safety | `{strong / partial / none}` | {1-line rationale citing the path + key signal, e.g. `tsconfig.json line 6: "strict": true`} |
| Module boundaries | `{strong / partial / flat}` | {1-line rationale, e.g. `src/domain/ + src/application/ + src/infrastructure/ all present`} |
| Framework opinionation | `{strong / moderate / weak}` | {1-line rationale, e.g. `package.json deps include @nestjs/core (DI + HTTP + persistence opinionation)`} |
| Test coverage signal | `{present / absent}` | {1-line rationale, e.g. `jest.config.js has coverageThreshold: { global: { lines: 80 } }`} |
| Lint baseline | `{present / absent}` | {1-line rationale, e.g. `.eslintrc.json present at repo root`} |

See AgDR-0042 for the scoring rationale and v1 thresholds.

## Quality Risks

### Security
- {known CVEs in deps, hardcoded secrets, missing auth, etc.}

### Dependencies
- {abandoned packages, major versions behind, license issues}

### Technical debt
- {missing tests, no types, dead code, tangled architecture, etc.}

### Operational
- {missing CI, no monitoring, no deploy automation, etc.}

## Integration Plan

### Roles that apply
- {tech-lead, backend-engineer, frontend-engineer, sre, security-auditor, …}

### Workflows that kick in
- [ ] PR workflow (`.claude/rules/pr-workflow.md`) — every change goes through a PR
- [ ] AgDR for technical decisions
- [ ] Code Reviewer agent on every PR
- [ ] Security Reviewer agent on first pass and high-risk PRs
- [ ] `/audit-deps` on adoption and monthly thereafter

### Hooks to enable
- [ ] `block-git-add-all`
- [ ] `block-main-push`
- [ ] `validate-branch-name` (set `ticket_prefix` for this project's tracker)
- [ ] `validate-pr-create`
- [ ] `pre-push-gate`
- [ ] `check-secrets`

### CI templates to copy in
- [ ] `golden-paths/pipelines/ci.yml`
- [ ] `golden-paths/pipelines/security.yml`
- [ ] `golden-paths/pipelines/pr-title-check.yml`

### Registry entry

The entry that will be appended to `apexyard.projects.yaml` at the root of the ops repo (see step 7 — the skill does this append for you, with confirmation):

```yaml
- name: {name}
  repo: {owner/name}
  workspace: workspace/{name}
  docs: projects/{name}
  status: handover
  roles:
    {dynamically derived from the tech stack + CI config — see
     "Deriving applicable roles" below}
```

**Deriving applicable roles**: don't hard-code `[tech-lead, backend-engineer]`. Look at the tech stack from step 3:

| Signal | Add role |
|--------|----------|
| Any backend code (package.json with server deps, pyproject.toml, etc.) | `backend-engineer` |
| Any UI code (React/Vue/Svelte, `src/components/`, CSS modules) | `frontend-engineer` |
| CI config detected (`.github/workflows/`, `.gitlab-ci.yml`, etc.) | `platform-engineer` |
| Production deployment evidence (Dockerfile, Terraform, AWS/GCP/Azure SDK) | `sre` |
| Auth / crypto / secrets in the diff | `security-auditor` |
| Always | `tech-lead` |

For a typical handover you'll end up with 3-5 roles in the list.

## Next Steps

Derived dynamically from the Quality Risks found in this assessment. Don't emit generic placeholders — emit specific actions.

Mapping table:

| Risk found | Next step entry |
|------------|-----------------|
| ≥ 1 CVE in deps (any severity) | `1. /audit-deps {name} — triage the {severity} {package} CVE before any new feature work` |
| Failing tests | `2. Fix the {N} failing tests in {module} before merging new PRs (baseline must be green)` |
| No observability (no Sentry/Datadog/CloudWatch/etc.) | `3. /decide on observability ({two most common options for this stack})` |
| Stale CI (no runs in > 30 days) | `4. Re-enable CI on this repo — copy in golden-paths/pipelines/ci.yml` |
| Test coverage unknown | `5. Set up test coverage reporting (vitest/jest coverage config) before the first feature` |
| ≥ 10 open issues | `6. Triage the issue backlog with the previous owner before taking ownership` |
| Missing README or onboarding doc | `7. Write a minimum-viable README (what the project does, how to run it locally, where it deploys)` |

If no risks match a row, omit that row. If fewer than 3 actions come out, add:

- `{next} /code-review the most-recent PR on this repo as Rex to calibrate review standards`
- `{next} Stakeholder sync with the previous owner to cover context the static read couldn't surface`

**Re-handover preservation.** On re-runs of `/handover`, the regenerated `## Next Steps` section MUST preserve any prior-run `~~strikethrough~~ → Filed as [#N](url)` markers on entries that recur in the new list. Detection rule: for each entry that would be emitted by the mapping table above, scan the prior `handover-assessment.md` (if present) for a matching entry by leading verb + key noun phrase (e.g. "Fix the N failing tests in {module}" matches the prior "Fix the M failing tests in {module}" regardless of the count). If matched and the prior version carries a `Filed as` link, preserve the link in the regenerated entry. This is the load-bearing input to step 7.5's filed-marker skip logic — without it, the operator gets re-prompted on every filed entry on every re-handover. See Rule 18.

## Cleanup (REQUIRED before exit)

```bash
rm -f .claude/session/active-bootstrap
```

Always remove the bootstrap marker on a clean exit. If the skill is interrupted before this step, `clear-bootstrap-marker.sh` clears the stale marker on the next session.

## Post-Handover Checklist

Also derived from the risks found. Tailor to the specific repo — don't emit generic items.

- [ ] Review this assessment with the previous owner
- [ ] {top quality risk} — close before the first feature PR
- [ ] {second quality risk} — scheduled in the first 2 weeks
- [ ] Add `{name}` to the weekly `/stakeholder-update` rollup
- [ ] Onboard the roles listed above into the team's on-call / review rotation
- [ ] Set up a test coverage baseline (run `npm test -- --coverage` or equivalent and commit the threshold)
- [ ] Run `/audit-deps {name}` monthly for the next 3 months

## Open Questions

- {anything you couldn't determine from a static read}

````

### 5.5. Instantiate the topology bundle (conditional on step 1.5 pick)

**Skip condition**: if `$PICKED_TOPOLOGY` is empty (operator chose "Skip / custom"), skip this entire step and note in the final summary `topology: skipped`.

If a topology was picked, copy the bundle into the project's instantiation locations. **All copies, never symlinks** — copies are stable across framework updates; `/update` detects drift on top (see AgDR-0048).

#### Resolve paths

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"

OPS_ROOT="$(git rev-parse --show-toplevel)"
TOPOLOGY_SRC="$OPS_ROOT/topologies/$PICKED_TOPOLOGY"
PROJECTS_DIR=$(portfolio_projects_dir)
WORKSPACE_DIR=$(portfolio_workspace_dir)
TOPOLOGY_VERSION=$(cat "$TOPOLOGY_SRC/VERSION")
```

#### Confirm before any write

Print a per-file plan and prompt for confirmation. This is destructive (creates new files); operator owns the decision.

```
Topology bundle: $PICKED_TOPOLOGY v$TOPOLOGY_VERSION
About to instantiate into the project:

  $PROJECTS_DIR/<name>/handbooks/                     ← all topology handbooks
  $PROJECTS_DIR/<name>/.topology/VERSION              ← version anchor for /update drift detection
  $PROJECTS_DIR/<name>/.topology/name                 ← topology name (one line: $PICKED_TOPOLOGY)
  $PROJECTS_DIR/<name>/docs/agdr/<stack>-<topology>.draft.md   ← stack-specific AgDR template (draft)
  workspace/<name>/.github/workflows/<topology-ci>.yml          ← CI pipeline (only if workspace clone exists)

Existing files at any of these paths will be PRESERVED (no overwrite). If you
want a clean re-instantiation, delete the files and re-run.

Proceed? [Y/n]
```

If the operator declines (`n`), set `TOPOLOGY_INSTANTIATED="declined"` and continue to step 6.

#### Copy handbooks

```bash
mkdir -p "$PROJECTS_DIR/<name>/handbooks"
# rsync if available (handles "preserve target if exists"); fall back to cp -n
if command -v rsync >/dev/null 2>&1; then
  rsync -a --ignore-existing "$TOPOLOGY_SRC/handbooks/" "$PROJECTS_DIR/<name>/handbooks/"
else
  cp -Rn "$TOPOLOGY_SRC/handbooks/." "$PROJECTS_DIR/<name>/handbooks/"
fi
```

The `--ignore-existing` / `-n` flag is load-bearing — adopters who've already started editing handbooks in the project keep their edits.

#### Write the topology anchor (for `/update` drift detection)

```bash
mkdir -p "$PROJECTS_DIR/<name>/.topology"
echo "$PICKED_TOPOLOGY" > "$PROJECTS_DIR/<name>/.topology/name"
cp "$TOPOLOGY_SRC/VERSION" "$PROJECTS_DIR/<name>/.topology/VERSION"
```

`/update` reads these two files to know which topology to diff against (see [`.claude/skills/update/SKILL.md`](../update/SKILL.md) § "Topology drift detection").

#### Seed the AgDR template (as a draft — `.draft.md` extension)

```bash
mkdir -p "$PROJECTS_DIR/<name>/docs/agdr"
TEMPLATE_FILE=$(ls "$TOPOLOGY_SRC/templates/agdr-"*.md 2>/dev/null | head -1)
if [ -n "$TEMPLATE_FILE" ]; then
  TEMPLATE_NAME=$(basename "$TEMPLATE_FILE" .md)
  TARGET="$PROJECTS_DIR/<name>/docs/agdr/${TEMPLATE_NAME}.draft.md"
  [ ! -f "$TARGET" ] && cp "$TEMPLATE_FILE" "$TARGET"
fi
```

The `.draft.md` extension is load-bearing: the AgDR-required hooks ignore `.draft.md` files, so the seed doesn't trigger spurious "AgDR not referenced" findings on the first PR. The operator renames `.draft.md` → `.md` when they fill it in.

#### Copy the CI pipeline (only if `workspace/<name>/` exists locally)

```bash
if [ -d "$WORKSPACE_DIR/<name>/.git" ]; then
  mkdir -p "$WORKSPACE_DIR/<name>/.github/workflows"
  for pipeline in "$TOPOLOGY_SRC/golden-paths"/*.yml; do
    [ -e "$pipeline" ] || continue
    target="$WORKSPACE_DIR/<name>/.github/workflows/$(basename "$pipeline")"
    if [ ! -f "$target" ]; then
      cp "$pipeline" "$target"
    fi
  done
fi
```

If the workspace clone doesn't exist yet (operator hasn't cloned), defer the pipeline copy — emit a one-line note: `topology pipelines pending — clone the repo into workspace/<name>/ then re-run /handover, or copy topologies/$PICKED_TOPOLOGY/golden-paths/*.yml manually`.

#### Set the instantiation marker for the final summary

```bash
TOPOLOGY_INSTANTIATED="$PICKED_TOPOLOGY@$TOPOLOGY_VERSION"
```

### 6. Write the L2 container diagram stub (if missing)

**Skip condition**: if `projects/<name>/architecture/container.md` already exists, skip this entire step and note it in the final summary (`architecture/container.md: preserved`). Never overwrite.

If missing: emit a stub Mermaid C4 container diagram derived from the repo signals gathered in step 3. The goal is a file the user can render on GitHub immediately and then refine — correctness beats completeness.

#### Container-detection signals

Scan the repo for these, in order. Stop at the first match per slot where it makes sense (only one `web`, only one primary `db`), but accumulate for multi-service slots (workers, caches, queues can coexist).

**Slot: `web` (frontend / SPA)**

| Signal | Label | Tech label |
|--------|-------|-----------|
| `package.json` has `next` or `@next/*` | Web App | `Next.js` |
| `package.json` has `react-scripts` | Web App | `React / CRA` |
| `package.json` has `vite` + React dep | Web App | `React / Vite` |
| `package.json` has `@remix-run/*` | Web App | `Remix` |
| `package.json` has `svelte` / `@sveltejs/kit` | Web App | `SvelteKit` |
| `package.json` has `nuxt` | Web App | `Nuxt` |
| `package.json` has `@angular/core` | Web App | `Angular` |
| `src/components/` or `src/pages/` exists | Web App | (infer from `package.json`) |

If none match → omit the web container. Not all projects have a frontend.

**Slot: `api` (HTTP backend)**

| Signal | Label | Tech label |
|--------|-------|-----------|
| `package.json` has `express` | API | `Node.js / Express` |
| `package.json` has `fastify` | API | `Node.js / Fastify` |
| `package.json` has `hono` | API | `Node.js / Hono` |
| `package.json` has `@nestjs/core` | API | `NestJS` |
| `package.json` has `koa` | API | `Node.js / Koa` |
| Next.js project with `app/api/` or `pages/api/` | API | `Next.js API routes` (same container as web, or split if clearly separate service) |
| `go.mod` has `net/http` handlers / `gin` / `echo` / `chi` / `fiber` | API | `Go / <framework>` |
| `pyproject.toml` has `fastapi` / `django` / `flask` | API | `Python / <framework>` |
| `Gemfile` has `rails` / `sinatra` | API | `Ruby / <framework>` |
| `Cargo.toml` has `axum` / `actix-web` / `rocket` | API | `Rust / <framework>` |

If the project is a monolith Next.js app with API routes, collapse `web` + `api` into one container labelled `Web App + API` with tech `Next.js` — don't fabricate a split the code doesn't have.

**Slot: `worker` (async / background jobs)**

| Signal | Label | Tech label |
|--------|-------|-----------|
| `package.json` has `bullmq` / `bee-queue` / `agenda` | Background Worker | `Node.js / <lib>` |
| `package.json` has `@inngest/*` | Background Worker | `Inngest` |
| `workers/` directory with job handlers | Background Worker | (infer) |
| `pyproject.toml` has `celery` | Background Worker | `Python / Celery` |

If none → omit.

**Slot: `db` (primary relational / document store)**

| Signal | Label | Tech label |
|--------|-------|-----------|
| `prisma/schema.prisma` with `datasource db { provider = "postgresql" }` | Primary Database | `PostgreSQL (Prisma)` |
| Same, provider = `mysql` / `sqlite` / `mongodb` / etc. | Primary Database | `<Provider> (Prisma)` |
| `drizzle.config.ts` or `drizzle.config.js` | Primary Database | `<driver> (Drizzle)` |
| `knexfile.{js,ts}` | Primary Database | `<client from config> (Knex)` |
| `DATABASE_URL` in `.env.example` with `postgres://` / `mysql://` / `mongodb://` | Primary Database | `<Protocol-derived>` |
| `supabase/config.toml` | Primary Database | `Supabase (PostgreSQL)` |
| `firebase.json` with firestore config | Primary Database | `Firestore` |

Use `ContainerDb(db, ...)` (the `Db` suffix changes the icon in Mermaid C4).

**Slot: `cache`**

| Signal | Label | Tech label |
|--------|-------|-----------|
| `package.json` has `ioredis` / `redis` / `@upstash/redis` | Cache | `Redis` |
| `REDIS_URL` / `UPSTASH_REDIS_URL` in `.env.example` | Cache | `Redis` |
| `package.json` has `memcached` / `memjs` | Cache | `Memcached` |

Use `ContainerDb(cache, ...)`.

**Slot: `queue` (if distinct from `worker`)**

| Signal | Label | Tech label |
|--------|-------|-----------|
| AWS SDK with SQS usage (grep for `@aws-sdk/client-sqs`) | Queue | `AWS SQS` |
| `package.json` has `kafkajs` | Queue | `Kafka` |
| `package.json` has `amqplib` / `@cloudamqp/*` | Queue | `RabbitMQ` |

Only include a separate queue container if it's clearly distinct from worker infrastructure — otherwise fold into the worker's tech label.

**Slot: external systems (from `System_Ext`)**

Infer from:

- Auth SDKs: `@auth0/*` / `@clerk/*` / `next-auth` / `@supabase/auth-*` → `Auth Provider`, tech `Auth0` / `Clerk` / etc.
- Payments: `stripe` / `@paddle/*` → `Payment Processor`
- Email: `postmark` / `@sendgrid/*` / `resend` / `@aws-sdk/client-ses` → `Email Provider`
- Storage: `@aws-sdk/client-s3` / `@vercel/blob` / `@cloudflare/r2` → `Object Storage`
- LLM: `openai` / `@anthropic-ai/sdk` / `@google-ai/*` → `LLM API`

Include only the externals you find evidence for. Don't fabricate a Stripe dependency.

**docker-compose.yml override**

If `docker-compose.yml` exists at the repo root, it's a stronger signal than `package.json` for container composition — the compose services ARE the containers. For each service:

- Map `image: postgres:*` or `image: mysql:*` → `ContainerDb(db, ...)`
- Map `image: redis:*` → `ContainerDb(cache, "Cache", "Redis", ...)`
- Map `image: node:*` / `image: python:*` / `image: ruby:*` with a `build:` context → generic `Container(...)`, use the build context path as a hint
- Map named application services (from `build: ./api`, `build: ./web`) to `api` / `web` slots

When compose and `package.json` conflict, trust compose — it describes the deployment shape the project actually runs in.

**Dockerfile-only**

If there's a `Dockerfile` at repo root but no `docker-compose.yml`: one container, tech = the `FROM` base image (e.g. `node:20-alpine`). Pair it with whatever `package.json` says is the runtime. Don't invent a database container without signal.

#### Assembling the file

Resolve the C4 container template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
container_template=$(portfolio_resolve_template architecture/c4-container.md)
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/architecture/c4-container.md` (the template shipped in #50). Adopters who want a customised C4 shape drop their version at `<private_repo>/custom-templates/architecture/c4-container.md`. See `templates/README.md` for the path-mirroring convention.

Start from the resolved template. Replace:

- `{Project Name}` → the project's real name (from the handover)
- The sample `System_Boundary` contents → the containers you detected
- The sample `Rel(...)` edges → a reasonable first pass:
  - `user → web` (HTTPS) if there's a `web`
  - `web → api` (HTTPS / JSON) if there's both
  - `api → db` (SQL or driver-specific) if there's a `db`
  - `api → cache` (TCP) if there's a `cache`
  - `api → worker` (enqueue) if there's a `worker`
  - `worker → <external>` (API) for each external the worker plausibly calls
  - `api → <external>` for each external the API plausibly calls

Also replace the bottom-of-file guidance section with a brief "Handover-generated — refine me" note so the user knows this was machine-drafted. Render the following literal blockquote + Maintenance section into the target file (the content below is the exact Markdown to write):

- A blockquote starting with `> **Note**: this diagram was auto-generated by /handover on YYYY-MM-DD from repo signals (package.json, docker-compose.yml, Dockerfile, Prisma schema, .env.example). It is a **starting point** — review and refine.`
- Continue with a bulleted list inside the blockquote:
  - "Container labels and tech strings — the detector may have picked a framework version wrong"
  - "Inferred relationships — user → web assumes HTTPS; adjust if your stack uses something else"
  - "External systems — anything your team uses that isn't in package.json (e.g. infra-only dependencies, direct cloud APIs called via HTTP) won't have been detected"
- Close with: `> Update the "Maintenance" section below once the diagram is stable.`
- Then a blank line, then a second-level heading `## Maintenance`, then one line: `(From the template — update when L2 containers change.)`

#### Write path

```
projects/<name>/architecture/container.md
```

Create `projects/<name>/architecture/` if missing.

#### If there's nothing meaningful to draw

If after scanning you find zero signals (no `package.json`, no `pyproject.toml`, no Dockerfile, no known framework, no DB), skip the file and note in the summary: `architecture/container.md: skipped (no container signals detected — add manually from the C4 container template — resolve via portfolio_resolve_template architecture/c4-container.md — when ready)`. Better to write nothing than fabricate a wrong diagram.

### 7. Append to the portfolio registry

**Don't just print the snippet** — offer to append it automatically:

```

Ready to add {name} to apexyard.projects.yaml? (y/n)
> y

```

If yes:

1. **Locate the registry**: `apexyard.projects.yaml` at the root of the ops repo. If missing, first copy from `apexyard.projects.yaml.example` and show the user a warning: `⚠ Registry didn't exist — created from .example. You may need to fill in other projects.`

2. **Append the entry**. Use `yq` if available for a safe YAML edit, otherwise append as plain text with careful indentation. Resolve the registry path via the helper (single-fork or split-portfolio — same code path):

   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
   REGISTRY=$(portfolio_registry)

   # Prefer yq for correctness
   if command -v yq >/dev/null 2>&1; then
     yq eval -i '.projects += [{"name": "{name}", "repo": "{owner/name}", "workspace": "workspace/{name}", "docs": "projects/{name}", "status": "handover", "roles": [{roles}]}]' "$REGISTRY"
   else
     # Fallback: plain text append
     cat >> "$REGISTRY" <<'YAML'
     - name: {name}
       repo: {owner/name}
       workspace: workspace/{name}
       docs: projects/{name}
       status: handover
       roles:
         - tech-lead
         - backend-engineer
   YAML
   fi
   ```

3. **Validate the result**:

   ```bash
   # Prefer yq or python -c 'import yaml; yaml.safe_load(open(path))'
   yq eval '.' "$REGISTRY" >/dev/null 2>&1 \
     || python3 -c "import sys, yaml; yaml.safe_load(open('$REGISTRY'))" 2>&1
   ```

   If validation fails: **restore the previous version** from a backup made before the write, print the parse error, and tell the user to fix it manually. Never leave the registry in a broken state.

4. **Confirm to the user**:

   ```
   ✓ Added {name} to apexyard.projects.yaml
     status: handover
     roles: {the derived list}
   ```

If the user says `n` at the prompt, print the snippet they'd need to copy manually and continue to step 8 without writing anything:

```
Skipping the auto-append. If you want to add it later, copy this into apexyard.projects.yaml:

  - name: {name}
    repo: {owner/name}
    workspace: workspace/{name}
    docs: projects/{name}
    status: handover
    roles: {derived list}
```

### 7.5. Offer to file Next Steps as tracker tickets

The assessment's `## Next Steps` section (written in step 5) enumerates concrete follow-up work derived from the risks found. By default those entries are static prose — the operator reads them in the markdown and translates each to a `/feature` / `/task` / `/bug` invocation by hand. Recommendations rot when that translation step has friction. This step closes the loop: surface each next-step entry inline, prompt y/n per item, and dispatch the right ticket-creation skill per accepted item.

#### Skip conditions

- **Zero next-step entries** (no risks found, no synthetic "calibrate review standards" / "stakeholder sync" entries either) → skip this step silently
- **All next-step entries already carry a `Filed as #N` marker** from a prior run (re-handover with no NEW entries since the last filing pass) → skip with a one-line note: `All next steps were filed in prior runs — no new tickets offered.`. Detection: scan the regenerated `## Next Steps` list; if every entry either already-carries a `Filed as [#N](...)` link preserved through step 5's regeneration OR is a duplicate of a prior-run entry that did, skip. Mixed states (some filed, some new) do NOT skip — new entries get offered while filed-already entries are silently skipped at the per-item prompt loop (see § "Surface the entries" below).
- **Operator opted out of the registry append at step 7** (answered `n` to "Ready to add {name} to apexyard.projects.yaml?") → skip. The project isn't in the registry, so ticket-source links pointing at `projects/<name>/handover-assessment.md` won't reach a teammate context.

#### Surface the entries

Scan the regenerated `## Next Steps` list. Partition into two buckets:

- **Already-filed** — entries that carry a `Filed as [#N](...)` link from a prior step 7.5 run (preserved through step 5's regeneration; see § Next Steps "Re-handover preservation"). These are skipped silently — the operator never sees them in the prompt.
- **Unfiled** — entries with no `Filed as` link. These are the only entries surfaced.

If the unfiled bucket has zero entries, fall through to the skip-condition "All next-step entries already carry a `Filed as #N` marker" and emit the one-line note. Otherwise print the unfiled entries (top 3-5 by mapping-table order), numbered:

```
Found 5 follow-up tasks in the assessment (2 were filed in a prior run — skipping). File any as tracker tickets?

  1. /audit-deps <name> — triage the high-severity lodash CVE before any new feature work
  2. Fix the 7 failing tests in src/api/orders before merging new PRs
  3. Set up test coverage reporting (vitest coverage config) before the first feature
  4. Triage the issue backlog with the previous owner before taking ownership
  5. Write a minimum-viable README (what the project does, how to run it locally, where it deploys)

Per-item y/n (or 'all', 'none', a comma-list like '1,3,5'):
```

The leading `(N were filed in a prior run — skipping)` parenthetical only appears when at least one prior-filed entry was found and skipped; on first-handover runs, omit it.

Accept:

- `all` or `y` — file every entry
- `none` or `n` or empty input — skip all
- Comma-separated indices (e.g. `1,3,5`) — file just those
- Per-item y/n if the operator wants to walk through them one at a time — fall back to interactive if the response doesn't match the bulk shapes

If the response is ambiguous, ask one clarification question; don't loop indefinitely. Default to skip-all on a second ambiguous answer.

#### Route each accepted item to the right skill (heuristic)

For each accepted entry, classify by shape + dispatch the matching ticket-creation skill:

| Entry shape | Skill | Why |
|-------------|-------|-----|
| Mentions a fix to broken behaviour ("Fix the N failing tests", "Resolve the X regression") | `/bug` | The work is to fix something measurably broken |
| Mentions triage / decision / strategy ("Triage the backlog", "`/decide` on observability") | `/task` | Investigative or decision-making work; no broken behaviour to fix |
| Mentions a new capability or scaffolding ("Set up coverage reporting", "Write a README", "Enable CI") | `/task` | Tech-debt or infra-fix; not user-facing capability so `/task` fits better than `/feature` |
| Mentions invoking another framework skill ("`/audit-deps` <name>", "`/code-review` the most-recent PR") | `/task` | The work is "run this skill against this project" — track as a task to do, not a feature to build |
| Mentions a stakeholder action ("Stakeholder sync", "Onboard role X") | `/task` | Coordination work; `/task` fits |

**Default to `/task` when in doubt.** The framework's `/feature` skill is reserved for user-facing capabilities, and handover-derived next-steps are almost never that shape. The heuristic above keeps the routing predictable rather than asking the operator to disambiguate per item.

If the operator disagrees with the auto-route (e.g. they want a specific item filed as `/feature` instead of `/task`), they can say `1 as feature` / `3 as bug` etc. inline. Honour the override; default to the heuristic when no override is given.

#### Dispatch with the assessment as the source

For each accepted item, dispatch the chosen skill with these inputs:

- **Title** pre-filled from the next-step entry — strip any leading skill-prefix (e.g. drop the `/audit-deps <name> —` lead to leave `triage the high-severity lodash CVE before any new feature work`), trim, capitalise the first letter
- **Body** pre-filled with the source line as the last paragraph:

  ```
  _Source: handover deep-dive on YYYY-MM-DD — see `projects/<name>/handover-assessment.md` in the ops fork (or in the private portfolio sibling repo for split-portfolio v2 adopters) for the assessment that surfaced this work._
  ```

  **Plain path, no markdown link.** The ticket is rendered against the TARGET repo's URL space on GitHub, but the assessment lives in the OPS FORK (or, for split-portfolio v2 adopters, the private sibling repo). A markdown link of any relative form would be dead-on-render. Naming the path as prose is honest about the cross-repo lookup the reader has to do, and survives the split-portfolio v2 case where the assessment isn't reachable from a public link at all.

- **Repo**: the just-adopted project's repo (the `repo:` field from the registry entry written in step 7)

The dispatched skills (`/task`, `/bug`, `/feature`) handle the full ticket-creation flow including the `validate-issue-structure.sh` gate + the active-issue-skill marker (per AgDR-0030).

#### Update the assessment doc post-filing

After all dispatched tickets land, rewrite the assessment's `## Next Steps` section in-place:

- Replace each prose entry that became a ticket with the ticket-link form: `1. ~~/audit-deps...~~ → Filed as [#42](https://github.com/<owner>/<repo>/issues/42)`
- Leave unfiled entries as-is (un-strikethrough, un-linked)

So a future reader of `handover-assessment.md` can see which next-steps became tickets and which are still TODO.

#### Failure handling

On the first ticket-creation failure (`validate-issue-structure.sh` exit, `gh` API error, network failure, etc.), STOP and report. Already-filed tickets stay (don't roll back); tell the operator exactly which ones did file:

```
[3/5] Filing "Triage the issue backlog with the previous owner before taking ownership"… ✗

Error from /task:
  {stderr from the dispatched skill}

Filed so far: 2 tickets (<owner>/<repo>#41, #42).
Remaining: 3 entries (not filed).

What now?
  1. Retry — re-run the same dispatch
  2. Skip — drop this entry, continue with the next 2
  3. Abort — stop here; the 2 already-filed tickets stay
```

Mirrors `/tickets-batch`'s failure-handling shape (see [`.claude/skills/tickets-batch/SKILL.md`](../tickets-batch/SKILL.md) § "Failure handling").

#### Report

Append to the step 10 summary:

```
Next-step tickets filed:   {N filed of M offered | none offered (zero risks) | declined (skipped all)}
```

If at least one was filed, also list them inline in the summary:

```
Filed follow-up tickets:
  #41 — /task — Triage lodash CVE                  — <repo URL>
  #42 — /bug  — Fix 7 failing tests in src/api/orders — <repo URL>
```

### 8. Offer the clone-first deep-dive option (recommended)

You've just produced a metadata-only handover. The next natural step is a deeper dive — security audit, threat model, code-quality assessment. Those skills benefit substantially from a local clone + LSP-aware tooling, so offer the clone-first path here, with the cost transparently disclosed. Default is **no clone** — the operator has to type `y` explicitly.

#### What to ask

Print a single offer block. Use the project name resolved earlier in the flow as `<name>`, and the registry's `repo` field (or the URL the operator gave in step 1) as `<repo-url>`. Don't paraphrase — the prompt below is the exact shape:

```
Want me to clone <name> into workspace/<name>/ now? It enables
LSP-aware navigation in /code-review, /threat-model, /security-review
and the post-handover discovery skills (~3-15× cheaper than grep on
shallow semantic queries; ~1.4-5× on multi-hop traces).

Cost: ~tens of MB on disk + a one-time clone. The clone is gitignored
from your fork (workspace/*/).

Note: LSP requires `ENABLE_LSP_TOOL=1` and a per-language Claude Code
LSP plugin installed (the plugin install is your problem — it's not
bundled). Cross-project semantic queries still need grep (LSP is
per-workspace). Cold-start on large monorepos can be 30+ seconds.
Decline now if you'd rather configure that first or skip the deep dive.

[y / n / later]
```

#### Cost-transparency requirements

The offer **must** explicitly disclose:

1. **`ENABLE_LSP_TOOL=1`** — the env var the harness reads to enable LSP
2. **Per-language plugin install is the adopter's problem** — don't pretend the clone alone enables LSP
3. **Disk cost** (~tens of MB) and gitignored status (`workspace/*/`)
4. **Cross-project queries still need grep** — LSP is per-workspace
5. **Cold-start cost on large monorepos** — 30+ seconds is realistic per the spike

If any of these aren't surfaced in the offer, the adopter accepts a deal they don't understand. Don't compress the prompt past these five.

#### Branching

**On `y`:**

1. Resolve `<repo-url>`. If the registry already has the repo slug (`me2resh/<name>` form), translate to `https://github.com/<owner>/<name>.git`. If the operator gave a path in step 1 instead of a URL, fall back to asking for the clone URL — never invent one.

2. Resolve the workspace dir via the portfolio helper, then skip cleanly if the project clone already exists:

   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
   WORKSPACE_DIR=$(portfolio_workspace_dir)
   mkdir -p "$WORKSPACE_DIR"

   if [ -d "$WORKSPACE_DIR/<name>" ]; then
     echo "✓ $WORKSPACE_DIR/<name>/ already exists — skipping clone."
   else
     git clone <repo-url> "$WORKSPACE_DIR/<name>"
   fi
   ```

   In single-fork mode `WORKSPACE_DIR` resolves to `<ops-root>/workspace`; in split-portfolio v2 mode it resolves to the sibling private repo (e.g. `../<fork>-portfolio/workspace`). Don't hardcode `workspace/<name>/`.

3. On clone failure (private repo without credentials, network error, repo moved): report the exit code, point at `gh auth login` or a manual `git clone` as the recovery, and continue to the final summary. Do **not** retry, do **not** fall back to a different URL — the operator picks up from there.

4. On clone success, suggest the next skill as a single follow-up question:

   ```
   ✓ Cloned into $WORKSPACE_DIR/<name>/.
     Want to run /threat-model against the new clone now? (y/n)
   ```

   If the operator declines, mention `/code-review` and `/security-review` as the other natural follow-ups, then continue to the final summary. The skill never invokes follow-up skills automatically — the operator confirms each one.

**On `n` or `later`:**

Skip silently — no side effects, no further prompts. The adopter can clone manually anytime with `git clone <repo-url> "$WORKSPACE_DIR/<name>"`. Continue to the final summary.

**On any other input:**

Treat as `n` (no clone). Don't loop the prompt — the offer is one-shot.

### 9. Offer validation (conditional, default-no)

If the project looks **dormant** by the heuristic — last commit > 90 days ago AND zero open PRs AND no recent issue activity (rough thresholds, the skill can probe `gh repo view` + `gh pr list` + `gh issue list` to compute) — ask:

```
This project looks dormant — run /validate-idea {name} to confirm it's
still worth investing in? y/n (default n)
```

If the user accepts, hand off to `/validate-idea {name}` (which reads the just-written `handover-assessment.md` as starting context and writes its output to `projects/{name}/validation/handover-validation.md`).

If the project is healthy (recent commits, active PRs/issues), skip the prompt entirely. Don't ask "should I validate?" on every handover — only when the dormancy signal warrants it.

### 10. Return a summary

```
Handover assessment written: projects/{name}/handover-assessment.md
Architecture stub:           projects/{name}/architecture/container.md ({written | preserved | skipped})
Topology bundle:             {"<name>@<version> instantiated (handbooks + AgDR draft + CI pipelines)" | "declined" | "skipped (no pick)" | "pipelines pending — workspace not cloned"}
Registry updated:            apexyard.projects.yaml ({added | skipped})
Next-step tickets filed:     {N filed of M offered | none offered (zero risks) | declined (skipped all) | skipped (registry not appended)}
Workspace clone:             workspace/{name}/ ({cloned | preserved | skipped (declined) | skipped (later) | failed: <reason>})
Validation:                  {"completed — verdict <GREEN|YELLOW|RED>" | "skipped" | "not offered (project is active)"}

Tech stack: {one-liner}
Build: {ok / failed}
Risks: {N items} ({highest severity})
Roles activated: {comma-separated}
Top 3 next steps (still TODO after step 7.5):
  1. {first dynamic step}
  2. {second dynamic step}
  3. {third dynamic step}

{If next-step tickets were filed, append this block:}
Filed follow-up tickets:
  #41 — /task — Triage lodash CVE                  — <repo URL>
  #42 — /bug  — Fix 7 failing tests in src/api/orders — <repo URL>
  ...
```

## Rules

1. **Read-only against the target repo** — never modify the target repo without explicit permission. (The ops repo IS modified — you append to the registry and create the assessment file — but that's the point.)
2. **Honest assessment** — if a build fails, say so. Don't paper over problems.
3. **Always seed `projects/<name>/`** — even if minimal.
4. **Auto-append to the registry** (with confirmation) — don't leave the user to copy-paste a snippet. Propose the append, validate the resulting YAML, roll back on failure.
5. **Derive roles from the stack** — don't hard-code `[tech-lead, backend-engineer]`. The roles list depends on the actual tech stack, CI config, and security surface detected in step 3.
6. **Derive next steps from the risks** — don't emit generic placeholders. Every "Next Step" must correspond to a specific finding from the Quality Risks section of the assessment.
7. **Never auto-clone** — ask for the path in step 1, and offer (default-no) the optional clone in step 8. Clone only happens on an explicit operator `y`; `n` / `later` / unrecognised input all skip cleanly.
8. **Never store secrets** — if `.env` is found, list its presence but never read its contents.
9. **Status starts at `handover`** — moves to `active` only after the integration plan is executed.
10. **Never break the registry** — if the YAML append breaks the file, restore the previous version and ask the user to edit manually.
11. **Never overwrite the architecture stub** — `projects/<name>/architecture/container.md` is written once on first handover, then owned by the team. Re-runs of `/handover` (e.g. if the tech stack changed) must preserve any manual refinements. If you want to regenerate, the user deletes the file first.
12. **Architecture stubs are starting points, not truths** — the auto-generated note at the top of the file explicitly tells the user to review and refine. Never claim the detector is authoritative.
13. **Topology instantiation never overwrites** — step 5.5 copies files with `rsync --ignore-existing` / `cp -n`. Adopters who edited a topology handbook keep their edits across re-runs. Drift detection lives in `/update` (see AgDR-0048).
14. **Default is no topology** — pick 4 (Skip / custom) is the default. The pre-topology flow is byte-for-byte preserved for adopters who don't want a bundle. Never auto-pick a topology based on tech-stack detection in v1 — let the operator choose.
15. **Next-step tickets are opt-in, never auto-filed** — step 7.5 always prompts the operator before any `gh issue create`. Bulk shapes (`all` / `none` / comma-list) are conveniences, not defaults. `none` and empty input are equivalent — skip-all is the safe default if the operator's intent is unclear.
16. **The routing heuristic is the default, not the law** — step 7.5's auto-route from next-step shape to `/feature` / `/task` / `/bug` is a sensible default. The operator can override per item (`1 as feature` / `3 as bug`). When in doubt, default to `/task` — handover-derived next-steps are almost never user-facing capabilities (`/feature` shape) and rarely strictly broken behaviour (`/bug` shape).
17. **Source-link every filed ticket back to the assessment** — each ticket dispatched in step 7.5 carries a `_Source: handover deep-dive on YYYY-MM-DD — see projects/<name>/handover-assessment.md_` footer. Without that link, the assessment's context (risks, harnessability score, build status) is invisible to anyone working the ticket later, and the recommendation traceability rot is exactly the failure mode this step exists to prevent.
18. **Re-runs surface deltas, not redundancy** — the filed-marker presence on each next-step entry is the source of truth for "already done". On re-handover, step 5's regeneration of `## Next Steps` MUST preserve any `~~strikethrough~~ → Filed as [#N](url)` markers from prior runs (don't blow away the operator's filing history). Step 7.5 then prompts only on the entries that lack a `Filed as` link, so the operator never re-sees what they've already filed. If every entry already carries a `Filed as` link, the whole step skips (see § Skip conditions). Byte-equivalence of the section text is NOT the test — only the per-entry marker presence is.

## When to use this

| Trigger | Use `/handover`? |
|---------|------------------|
| Inherited a codebase from another team | Yes |
| Acquired a company's repo | Yes |
| Adopted an open-source project as a dependency | No — that's `/audit-deps` |
| Forked an internal tool you wrote yesterday | No — it's already yours |
| Importing a side project into the org | Yes |

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

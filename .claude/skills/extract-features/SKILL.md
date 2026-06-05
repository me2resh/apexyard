---
name: extract-features
description: Six-axis Feature Inventory (routes / models / jobs / tests / UI / docs) — a "what we must preserve" spec for greenfield rewrites.
argument-hint: "[project-name] [--with-mockups]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /extract-features — Feature Inventory for Greenfield Rewrites

Walks the target project's codebase across **six discovery axes** and writes a consolidated Feature Inventory. The artefact is the "what we must preserve" specification for a greenfield rewrite (different language, framework, or architecture) — instead of reverse-engineering features one route at a time, hand the inventory to the rewrite team.

This skill complements `/handover`:

- `/handover` produces a **high-level project assessment** — origin, current health, integration plan, applicable roles. The output is the bridge between "we just inherited this codebase" and "this codebase is now governed by our normal SDLC".
- `/extract-features` produces a **granular feature catalogue** — every route, model, job, test name, UI screen, and documented capability the existing system exposes. The output is the input to a greenfield-rewrite spec.

Run `/handover` first when adopting an unfamiliar repo; run `/extract-features` second when you've decided to rewrite it.

**See also**: [`/feature-diagram <feature-slug>`](../feature-diagram/SKILL.md) — once the inventory exists, this skill emits a per-feature Mermaid sub-graph (routes + models + jobs + screens for one feature) at `projects/<name>/features/<slug>.md`. The inventory's `Feature` column gains a link to each per-feature diagram. Sibling to `/c4` (system topology) and `/dfd` (data flows) in the architecture-doc family — different lens (per-feature slice) on the same codebase. See `AgDR-0035` for the design rationale.

## LSP-aware (optional, recommended)

Discovery walks across all six axes — `documentSymbol`, `references`, `definition` queries — are the obvious win for LSP. With `ENABLE_LSP_TOOL=1` + per-language plugin (per `docs/getting-started.md` § "Optional: LSP-aware code navigation"), route-handler enumeration, model walks, and test-name extraction are ~3-15× cheaper in token cost than grep + Read. Without LSP, the skill falls back to grep transparently using the framework signatures listed below. No new failure mode, just optional speed.

The skill detects the active language from `package.json` / `pyproject.toml` / `Gemfile` / `go.mod` / `Cargo.toml` and dispatches to the matching axis-walker logic regardless of LSP state.

## Path resolution

Read the registry path via `portfolio_registry` and the per-project docs dir via `portfolio_projects_dir` from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
```

Defaults match today's single-fork layout (`./projects`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir}` keys in `.claude/project-config.json` — the helper resolves whichever mode they're in. See `docs/multi-project.md`.

**Write targets** (see me2resh/apexyard#373 + #443): paths documented as `projects/<name>/X` in this skill are canonical adopter-facing forms — implement them in bash as `"${projects_dir}/<name>/X"`. Never construct from `"${PWD}/projects/..."`, `"$(git rev-parse --show-toplevel)/projects/..."`, or a literal `./projects/...` — those break in split-portfolio v2 mode where `projects_dir` resolves to a sibling repo.

**REQUIRED per-block preamble** (see #443): Claude executes each ```bash``` block as a separate shell invocation. The `projects_dir` assignment from the Path resolution section above does NOT carry into later blocks. Every bash block that writes to a `projects/<name>/X` path MUST start with this three-line preamble so it's self-contained:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
# ... now write to "${projects_dir}/<name>/X"
```

The Path resolution section's example sources the helper *once* for documentation purposes; it does not absolve later blocks from sourcing it themselves. Treat each ```bash``` fence as a fresh process.

## Usage

```
/extract-features                              # current project (cwd inside workspace/<name>/)
/extract-features billing-api                  # registered project; resolve to workspace/billing-api/
/extract-features .                            # treat cwd as the project root
/extract-features billing-api --with-mockups   # also emit AI-inferred ASCII wireframes per UI screen
```

If `<project-name>` is given but `workspace/<name>/` doesn't exist, the skill stops and asks the user to clone the project (it does not auto-clone — that's a side-effect with cost; same convention as `/handover`).

### `--with-mockups` (opt-in, default off)

When set, the inventory file gains a new `## Screens` section after the existing axes. For each UI screen discovered in axis 5, the skill emits a low-fidelity **ASCII wireframe** — boxed layout, form fields (`[ ]` text, `[v]` dropdown, `[X]` checkbox, `[ Button ]` button), tables as ASCII grids, max 80 chars wide.

The wireframes are **model-inferred from static analysis** — route component imports, form-field bindings, data-model field types. They're not lifts from real DOM. Two design constraints follow:

1. **ASCII format only.** No PNG/SVG/HTML. ASCII boxes keep the fidelity honest — a reader sees a sketch and treats it as a sketch.
2. **Mandatory disclaimer header per wireframe.** Every screen wireframe carries `> AI-inferred sketch — verify before relying on. Source: <route-or-component-path>` on its own line above the box.

Backward-compat: running `/extract-features` without `--with-mockups` produces today's inventory exactly — the flag adds the `## Screens` section; nothing else changes.

File-size policy: if more than **10 UI screens** are detected, the skill writes one file per screen under `<projects_dir>/<name>/screens/<slug>.md` and the `## Screens` section in the inventory becomes a linked index. Threshold rationale in [`AgDR-0036`](../../../docs/agdr/AgDR-0036-inferred-mockups-honesty.md).

## Output location

```
projects/<name>/feature-inventory.md          ← the artefact
```

The file is a **one-off scan**, not a recurring audit. There is no audit-history rotation. If the file already exists, the skill OFFERS (default-no) to overwrite — accept only if the codebase has changed substantially since the last run.

## Custom template override (forward-looking)

If `custom-templates/extract-features.md` exists in the configured custom-templates root (per the framework's template-override layer, when available), use it as the artefact template. Otherwise use the framework default in step 4 below. Resolve via:

```bash
custom_template=""
if [[ -n "${APEXYARD_CUSTOM_TEMPLATES_ROOT:-}" ]] \
   && [[ -f "${APEXYARD_CUSTOM_TEMPLATES_ROOT}/extract-features.md" ]]; then
  custom_template="${APEXYARD_CUSTOM_TEMPLATES_ROOT}/extract-features.md"
fi
```

If the template-override layer is not yet present in this fork, the variable is unset and the skill silently uses the default. Single-fork mode adopters are unaffected.

## Process

### 0. Resolve the target

- If the argument is `.` → use cwd.
- If the argument names a registered project → resolve to `workspace/<name>/` (the live working copy). If the workspace clone doesn't exist, prompt the user to clone first; do not auto-clone.
- If no argument and cwd is inside `workspace/<name>/` → use that project.
- If no argument and cwd is the ops-fork root → ask which registered project.

If the resolved target has none of the discovery signals (no `package.json`, `pyproject.toml`, `Gemfile`, `go.mod`, `Cargo.toml`, no source dirs) → stop and tell the user there's nothing to scan.

Capture and report the **scope**: which subdirectories will be walked, which will be skipped (vendored: `node_modules`, `vendor`, `.venv`, `target`, `dist`, `build`, `coverage`, `.next`, `.nuxt`).

### 1. Detect the tech stack

Same detection table as `/handover` step 3 — minimum information to dispatch the per-axis walkers:

| Signal | Stack |
|--------|-------|
| `package.json` | Node — read `dependencies` / `devDependencies` to identify framework |
| `pyproject.toml` / `requirements.txt` / `setup.py` | Python |
| `Gemfile` / `Gemfile.lock` | Ruby |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `composer.json` | PHP |
| `pom.xml` / `build.gradle` | JVM |

Multiple stacks in one repo (monorepo, polyglot) → walk each subroot independently and merge findings under one inventory.

### 2. Walk the six discovery axes (in parallel where possible)

Run the six axis-walkers below. Each produces a list; the consolidated matrix in step 3 dedupes across axes (a route handler covered by a test name shouldn't appear twice under different "features").

When LSP is enabled and the per-language plugin is installed, prefer `documentSymbol` over grep for handler / class / function enumeration. When LSP is absent, use the grep signatures listed.

#### Axis 2a — HTTP routes / entry points

Routes describe the **HTTP shape** of the system — every URL the system exposes is a candidate user-facing feature.

| Framework | Signature (grep fallback) |
|-----------|---------------------------|
| Express / Connect | `app\.(get\|post\|put\|patch\|delete\|all)\s*\(` ; `router\.(get\|post\|...)` |
| Fastify | `(fastify\|app)\.(get\|post\|put\|patch\|delete\|route)\s*\(` |
| NestJS | `@(Get\|Post\|Put\|Patch\|Delete\|All\|Options\|Head)\s*\(` |
| Hapi | `server\.route\s*\(` |
| Hono / Koa | `app\.(get\|post\|...)`; `router\.(get\|post\|...)` |
| Next.js (Pages Router) | files under `pages/api/**/*.{ts,tsx,js,jsx}` |
| Next.js (App Router) | files named `route.{ts,js}` under `app/**` |
| Remix | files named `loader\|action` exports under `app/routes/**` |
| FastAPI | `@(app\|router)\.(get\|post\|put\|patch\|delete\|api_route)\s*\(` |
| Flask | `@(app\|bp)\.route\s*\(` ; `@(app\|bp)\.(get\|post\|put\|patch\|delete)` |
| Django | `urls.py` → `path(`, `re_path(`, `url(` ; class-based views; DRF `@api_view`, `routers.register` |
| Rails | `config/routes.rb` → `get`, `post`, `resources`, `resource`, `namespace`, `scope` |
| Sinatra | `^\s*(get\|post\|put\|patch\|delete)\s+['"]` |
| Gin | `router\.(GET\|POST\|PUT\|PATCH\|DELETE\|Handle)\s*\(` |
| Echo | `e\.(GET\|POST\|...)` ; `g\.(GET\|POST\|...)` |
| Chi / Fiber | `r\.(Get\|Post\|...)` ; `app\.(Get\|Post\|...)` |
| Axum | `Router::new()\.route\s*\(` |
| Actix-web | `\.service\s*\(` ; `web::(get\|post\|put\|patch\|delete)` |
| Rocket | `#\[(get\|post\|put\|patch\|delete)` |
| Laravel | `routes/web.php`, `routes/api.php` → `Route::(get\|post\|...)` |
| Spring | `@(GetMapping\|PostMapping\|PutMapping\|PatchMapping\|DeleteMapping\|RequestMapping)` |
| AWS SAM / Serverless | `template.yaml` / `serverless.yml` → `Events:` with `Api:` / `HttpApi:` |
| GraphQL | `Query\|Mutation\|Subscription` resolver definitions; SDL `.graphql` files |

For each route capture: HTTP method, path, handler symbol (file + line), and any docstring / comment immediately above. The handler name + comment is usually a strong feature signal.

#### Axis 2b — Data models / DB schema

Models describe the **data shape** of the system — every persistent entity and its relations.

| Framework | Signature |
|-----------|-----------|
| Prisma | `prisma/schema.prisma` → `model X { ... }` blocks; `prisma/migrations/**` |
| TypeORM | `@Entity\(\)` decorators; classes extending `BaseEntity` |
| Sequelize | `sequelize.define\s*\(` ; classes extending `Model` |
| Drizzle | `pgTable\|mysqlTable\|sqliteTable\s*\(` ; `drizzle.config.{ts,js}` |
| Mongoose | `mongoose\.(model\|Schema)` ; `new Schema\s*\(` |
| Knex | `knexfile.{js,ts}`; `knex.schema.createTable` in migrations |
| SQLAlchemy | classes extending `Base` / `db.Model` ; `__tablename__` ; `Column(` |
| Django ORM | `models.py` → classes extending `models.Model` |
| Active Record (Rails) | `app/models/**/*.rb` → `class X < ApplicationRecord`; `db/schema.rb` ; `db/migrate/**` |
| GORM (Go) | structs with `gorm:` tags; `db.AutoMigrate(` |
| Diesel (Rust) | `table!` macro; `schema.rs` |
| ActiveRecord-Java (JPA / Hibernate) | `@Entity` annotations |
| Raw SQL | `migrations/**/*.sql` ; `db/schema.sql` |

For each model capture: name, table name (if different), field list (name + type), relations (`@OneToMany`, `belongs_to`, `references`), and any unique / index constraints. Field names hint at features (an `email_verified_at` column implies email-verification flow).

#### Axis 2c — Async jobs / queue handlers

Background jobs describe **deferred work** — usually one job = one async feature (send email, generate report, sync external system).

| Framework | Signature |
|-----------|-----------|
| BullMQ / Bull | `new Queue\s*\(` ; `new Worker\s*\(` ; `\.process\s*\(` |
| Bee-queue | `new Queue\s*\(` (with `bee-queue` import) |
| Agenda | `agenda\.define\s*\(` |
| Inngest | `inngest\.createFunction\s*\(` ; `serve\(\{ functions:` |
| node-cron | `cron\.schedule\s*\(` |
| Celery | `@app\.task` ; `@shared_task` ; `@task` |
| RQ | `Queue\(.*\)\.enqueue` |
| APScheduler | `scheduler\.add_job` ; `@scheduler\.scheduled_job` |
| Sidekiq | classes including `Sidekiq::Worker` / `Sidekiq::Job` ; `perform\(` method |
| Resque | classes with `@queue =` |
| Active Job (Rails) | `app/jobs/**/*.rb` → `class X < ApplicationJob` |
| AWS SQS handlers | Lambda handlers with `Records[].eventSource == "aws:sqs"` ; SAM `Events: SQS:` |
| AWS EventBridge / cron | SAM `Events: Schedule:` ; CloudWatch Events rules |
| Cron defs | `crontab` files; `*/N * * * *` patterns in YAML / config |
| Temporal / Cadence | `@workflow.defn` ; `@activity.defn` |
| Faktory | classes including `Faktory::Job` |

For each job capture: name, trigger (queue name, cron expression, event source), and the handler function. Job names are typically verb-phrases that name a feature directly.

#### Axis 2d — Test names (the gold axis)

**Test names are the cheapest, most accurate signal of what a system DOES** — they're written by humans deliberately describing behaviour. Routes describe HTTP shape; models describe data shape; **tests describe behaviour**. Walking test names surfaces features that routes + models can't (e.g. "user can recover password via email", "admin can bulk-delete users with confirmation").

| Framework | Signature |
|-----------|-----------|
| Jest / Vitest / Mocha | `describe\s*\(\s*['"`]` ; `it\s*\(\s*['"`]` ; `test\s*\(\s*['"`]` |
| Playwright / Cypress | `test\s*\(\s*['"`]` ; `describe\s*\(\s*['"`]` ; `it\s*\(\s*['"`]` |
| pytest | `def test_[a-z_]+\s*\(` ; class `Test\w+:` |
| unittest | `def test_[a-z_]+\s*\(self` ; class `(\w+)\s*\(\s*unittest\.TestCase` |
| RSpec | `describe\s+['"]` ; `context\s+['"]` ; `it\s+['"]` |
| Minitest | `class \w+ < (Minitest::Test\|ActiveSupport::TestCase)` ; `def test_\w+` ; `it ['"]` |
| Go testing | `func Test\w+\(t \*testing\.T\)` ; `t\.Run\s*\(\s*"` |
| Cargo test | `#\[test\]` ; `mod tests` ; `fn \w+\(\)` inside `tests` module |
| JUnit | `@Test` annotations; method names `void should_\w+` ; `void test\w+` |
| PHPUnit | `function test\w+\(` ; `@test` docblocks |

For each test capture: the full describe/context/it sentence (concatenated for nested specs). Cluster the sentences — patterns like "user can …", "admin can …", "guest cannot …" reveal features and roles.

#### Axis 2e — UI screens / forms / interactions

UI components describe the **interaction surface** of the system — every screen, form, and named interaction is a candidate feature.

| Framework | Signature |
|-----------|-----------|
| React (router) | `react-router-dom` `<Route path=`; Next.js `pages/**`; Next.js `app/**/page.{tsx,js}`; Remix `app/routes/**` |
| React (components) | top-level `function\|const \w+ = ...` returning JSX in `src/components/`, `src/screens/`, `src/pages/`, `src/views/` |
| Vue | `.vue` files; `defineComponent\s*\(` ; route files (`router/index.ts`) |
| Svelte / SvelteKit | `routes/**/+page.svelte` ; `routes/**/+layout.svelte` ; `.svelte` components |
| Angular | `@Component\s*\(` ; `RouterModule\.forRoot\s*\(\s*\[` ; `path:` entries |
| Form libraries | `<form>` tags; `useForm\(`; `react-hook-form` `register\(`; `formik`; `<Field name="`; Vue `v-model` |
| Storybook | `*.stories.{ts,tsx,js,jsx,mdx}` files — story names are user-flow names |
| Tailwind / CSS modules | not features themselves, but presence indicates UI surface area |
| Mobile (RN) | `react-navigation` `Stack.Screen name=` ; `<Tab.Screen name=` |
| Mobile (Flutter) | `MaterialPageRoute` ; `GoRoute` ; `Navigator.push` |

For each screen capture: route path (if router-mapped), component name, and the form fields it contains (if any). Form-field names + labels are explicit feature signals (a `confirmEmail` field implies email-verification UX).

#### Axis 2f — Documented features

Documented features are the **author's own enumeration** — usually the most accurate but least complete (often stale).

Sources:

- `README*` — look for "Features" / "What it does" sections (`^##\s+Features?` headers and the bullet list that follows)
- `docs/features/**` — entire directory if present
- `docs/index.md` / `docs/README.md` — top-level docs
- `CHANGELOG*` — extract `## [Unreleased] Added` and historical `### Added` blocks
- `CONTRIBUTING.md` — sometimes includes a feature taxonomy
- API docs (`openapi.yaml`, `swagger.json`) — every operation summary is a feature
- GitHub Issues with `enhancement` / `feature` labels (closed) — can hint at what shipped, but treat as supplementary

For each documented feature capture: title, source (file + line), and the description verbatim. This is the only axis where the author's intent is recorded; the other five infer it from the code.

### 3. Consolidate

Build a **single feature matrix** that dedupes findings across the six axes. The matrix columns:

| Column | Source |
|--------|--------|
| Feature | Inferred name (verb-phrase preferred: "Create order", "Reset password via email", "Bulk-delete users") |
| Surface | UI / API / Job / Internal — the entry point the user / operator interacts with |
| Status | Active (referenced from a current code path) / Deprecated (only in CHANGELOG / removed code) / Untested (route exists, no test names match) |
| Source | Which axes corroborated the feature — e.g. `route + test`, `model + UI`, `doc only` |
| Notes | Constraints, side effects, integrations the scanner spotted (e.g. "sends email via SendGrid", "Stripe webhook required", "rate-limited to 10/min") |

Deduplication rules:

- A route + a test that exercises it + a UI form that posts to it → **one** matrix row, sources: `route + test + UI`
- A model with no route and no test → still a row (data feature), sources: `model only`
- A documented feature not corroborated by code → row with `Status: Documented but not found in code` and a note flagging stale docs

Aim for **30-150 rows** for a typical mid-sized app. If you produce fewer than 10 rows on a non-trivial codebase, the walker missed signatures — flag in "Coverage gaps".

### 4. Write the inventory

Default template (used when no custom override is configured):

````markdown
# {project-name} — Feature Inventory

**Date**: {YYYY-MM-DD}
**Scanner**: `/extract-features` (apexyard)
**Scope**: {repo path}
**Stack detected**: {language(s) + framework(s) from step 1}

## Coverage scope

**Walked**:
- {list of subdirectories actually scanned, e.g. `src/`, `app/`, `tests/`, `docs/`}

**Skipped** (vendored / generated / fixtures):
- {list of directories pruned, e.g. `node_modules/`, `dist/`, `.next/`, `coverage/`, `tests/fixtures/`}

**Axes that produced findings**:
- {checked list of the six axes, with `(N items)` per axis}

## Consolidated feature matrix

| # | Feature | Surface | Status | Source | Notes |
|---|---------|---------|--------|--------|-------|
| 1 | Create order | API + UI | Active | route + test + UI | POST `/api/orders`; charges Stripe; sends confirmation email |
| 2 | Reset password via email | UI + Job | Active | route + test + UI + job | one-time token expires in 1h |
| ... | ... | ... | ... | ... | ... |

## Per-axis findings

### HTTP routes / entry points ({N})

| Method | Path | Handler | File | Notes |
|--------|------|---------|------|-------|
| ... | ... | ... | ... | ... |

### Data models / DB schema ({N})

| Model | Table | Fields | Relations | File |
|-------|-------|--------|-----------|------|
| ... | ... | ... | ... | ... |

### Async jobs / queue handlers ({N})

| Job | Trigger | Handler | File |
|-----|---------|---------|------|
| ... | ... | ... | ... |

### Test names ({N})

Grouped by file or feature cluster:

#### `tests/orders.test.ts`
- Order creation › creates order with valid payload › returns 201
- Order creation › rejects invalid currency › returns 400
- Order creation › sends confirmation email on success
- ...

### UI screens / forms / interactions ({N})

| Route | Component | Fields | File |
|-------|-----------|--------|------|
| ... | ... | ... | ... |

### Documented features ({N})

| Title | Source | Description |
|-------|--------|-------------|
| ... | ... | ... |

{IF --with-mockups, INSERT the `## Screens` section here. Each wireframe carries
the mandatory disclaimer header `> AI-inferred sketch — verify before relying
on. Source: <path>` on its own line above the ASCII box. See step 4b.}

## Coverage gaps

The scanner could **not** determine these — they need human review of the existing code or stakeholder interviews:

- **Business rules embedded in code logic** — discount stacking, eligibility checks, fraud heuristics. The scanner sees the function, not the policy.
- **Integration patterns** — webhook signature schemes, retry policies, dead-letter queues unless they're explicit in IaC.
- **Permission / authorisation matrix** — which roles can do what. Routes show endpoints; only manual review of guards / middleware reveals the full matrix.
- **Configuration-driven behaviour** — feature flags, environment-specific toggles.
- **Implicit features in cron / SQS handlers** with generic names — a job called `process_queue` doesn't name a feature.
- **Data-cleanup / TTL policies** — usually only in DB triggers or cron specs.
- **Stale documented features** — entries in CHANGELOG / README that reference removed code.

## Recommended next steps

1. **Review with the previous owner** — reconcile the matrix with their mental model. Expect ~10-20% drift (features they think exist that don't, features that exist they forgot about).
2. **Write user stories per matrix row** — translate "GET /api/orders" into "As a customer, I want to view my orders". The inventory is the input; user-story authoring is a human task (consider `/feature` for each story you intend to ship in v1).
3. **Identify the smallest-coherent-subset for v1 of the rewrite** — not every feature needs to ship in the first release. Bucket features into `must-have v1` / `nice-to-have v1.x` / `defer / drop`.
4. **Validate the deferred / dropped buckets with stakeholders** — the prior-art bias makes the inventory feel exhaustive, but rewriting is also an opportunity to drop dead weight.
5. **Run `/handover {project-name}`** if not already — for the high-level project assessment and integration plan that complements this granular inventory.
6. **Use `/c4 {project-name} --level=2`** to capture the existing system's container topology — pairs well with the inventory as input to a rewrite design.

## Open questions

- {anything axis-specific the scanner couldn't resolve, e.g. "saw `app.use(authMiddleware)` but couldn't trace the auth scheme — JWT? session? OAuth?"}

````

### 4b. Emit ASCII wireframes (only when `--with-mockups` is set)

For each UI screen captured in axis 2e, build a low-fidelity ASCII wireframe. Append the section to the inventory if 10 or fewer screens; write per-screen files at `<projects_dir>/<name>/screens/<slug>.md` and replace the inventory's `## Screens` body with a linked index if more than 10 screens.

#### Disclaimer header (MANDATORY — every wireframe)

Every wireframe carries this exact one-line header on its own line **above** the box:

```
> AI-inferred sketch — verify before relying on. Source: <route or component path>
```

The `<route or component path>` is the source detection result from the rules below — the file (or route) the wireframe was inferred from. No exceptions. A wireframe without a disclaimer is a broken artefact.

#### Source detection (the `Source:` value in the disclaimer)

Pick the strongest signal available, in this order:

| Stack | Source |
|-------|--------|
| Next.js (App Router) | `app/<segments>/page.{tsx,jsx,js}` |
| Next.js (Pages Router) | `pages/<path>.{tsx,jsx,js}` |
| Remix | `app/routes/<route>.{tsx,jsx,js}` |
| SvelteKit | `src/routes/<path>/+page.svelte` |
| React Router (declared) | the route's `element=` component file (e.g. `src/pages/LoginPage.jsx`) |
| Vue Router | the route's `component:` SFC path (e.g. `src/views/Login.vue`) |
| Angular | the route's `component:` path |
| Plain component (no router) | the component file itself (e.g. `src/components/SignupForm.tsx`) |

If a screen has both a route AND a component, prefer the route (it's the user-addressable name) and reference the component in the inventory's "UI screens" table.

#### Inference rules

The wireframe is built from these signals — all available **statically**, no runtime probing:

| Signal | Inferred wireframe element |
|--------|---------------------------|
| Imported `<TopNav>` / `<Header>` / `<NavBar>` component | Top nav strip at the top of the box |
| Imported `<Sidebar>` / `<SideNav>` / `<Drawer>` (persistent) | Left sidebar column |
| Imported `<Footer>` | Footer strip at the bottom of the box |
| `<Modal>` / `<Dialog>` / `<Drawer>` (as the root return) | Centered modal layout (smaller box, dimmed-overlay hint) |
| Form components (`<form>`, `useForm`, `react-hook-form`, `Formik`, Vue `v-model`) | Form section with one row per field |
| Form field bound to a `string` model field, or `<input type="text\|email\|password">` | `Field name: [ ____________________ ]` |
| Form field bound to a `boolean` model field, or `<input type="checkbox">` | `[ ] Field label` (use `[X]` for default-checked) |
| Form field bound to an `enum` model field, `<select>`, `<Dropdown>`, `<RadioGroup>` | `Field name: [v ____________________ ]` (the `v` denotes dropdown caret) |
| Foreign-key field (Prisma `@relation`, `belongs_to`, etc.) | `Field name: [v ____________________ ]` |
| Form field bound to `number` / `int` / `float` model field | `Field name: [ 0__________________ ]` |
| `<textarea>` or string field with `@db.Text` / large size hint | Multi-line `[ ___________________ ]` (3 lines) |
| `<button type="submit">` / `<Button>` with submit semantics | `[ Submit ]` (use the actual label when known) |
| Cancel / secondary buttons | `[ Cancel ]` |
| `<Table>` / `<DataGrid>` / `<List>` imports bound to a model | ASCII grid: header row from model fields, 2-3 stub data rows |
| `<Card>` clusters in a dashboard layout | Boxed cards in a grid; chart placeholders as `[░░ chart ░░]` |

When a signal is absent (no nav, no footer, etc.), omit that element entirely. **Do not invent layout the code doesn't imply.**

#### Box drawing conventions

Use ASCII box-drawing with `+`, `-`, `|`. Maximum width **80 chars** (the disclaimer line is exempt). Examples:

**Form-heavy screen**:

```
+----------------------------------------------------------------------------+
| TopNav: [Logo]  Home  Orders  Account                          [Log out]  |
+----------------------------------------------------------------------------+
|                                                                            |
|   Sign in                                                                  |
|                                                                            |
|   Email:    [ _______________________________________________________ ]    |
|   Password: [ _______________________________________________________ ]    |
|   [ ] Remember me                                                          |
|                                                                            |
|   [ Sign in ]   [ Forgot password? ]                                       |
|                                                                            |
+----------------------------------------------------------------------------+
```

**Table-heavy screen**:

```
+----------------------------------------------------------------------------+
| TopNav: [Logo]  Home  Orders  Account                          [Log out]  |
+----------------------------------------------------------------------------+
|                                                                            |
|   Orders                                            [ + New order ]        |
|                                                                            |
|   +-------+-------------+----------+--------+----------+-----------+       |
|   | ID    | Customer    | Total    | Status | Created  |           |       |
|   +-------+-------------+----------+--------+----------+-----------+       |
|   | 1001  | ...         | ...      | ...    | ...      | [ View ]  |       |
|   | 1002  | ...         | ...      | ...    | ...      | [ View ]  |       |
|   | 1003  | ...         | ...      | ...    | ...      | [ View ]  |       |
|   +-------+-------------+----------+--------+----------+-----------+       |
|                                                                            |
+----------------------------------------------------------------------------+
```

**Modal screen**:

```
+----------------------------------------------------------------------------+
|  ░░░░░░░░░░░░░░░░░░░░░░░ (dimmed background) ░░░░░░░░░░░░░░░░░░░░░░░░░░░  |
|                                                                            |
|             +----------------------------------------------+               |
|             |  Confirm deletion                       [X]  |               |
|             +----------------------------------------------+               |
|             |                                              |               |
|             |  Are you sure you want to delete this        |               |
|             |  order? This action cannot be undone.        |               |
|             |                                              |               |
|             |              [ Cancel ]   [ Delete ]         |               |
|             +----------------------------------------------+               |
|                                                                            |
+----------------------------------------------------------------------------+
```

**Dashboard screen (mixed cards + chart)**:

```
+----------------------------------------------------------------------------+
| TopNav: [Logo]  Home  Orders  Account                          [Log out]  |
+--------------+-------------------------------------------------------------+
| Sidebar      |                                                             |
|  - Overview  |   Overview                                                  |
|  - Orders    |                                                             |
|  - Users     |   +----------------+ +----------------+ +----------------+  |
|  - Settings  |   | Orders today   | | Revenue (MTD)  | | Active users   |  |
|              |   |   [   142   ]  | |  [  $12,840 ]  | |   [   893   ]  |  |
|              |   +----------------+ +----------------+ +----------------+  |
|              |                                                             |
|              |   Orders over time                                          |
|              |   [░░░░░░░░░░░░░░░░░░░░ chart ░░░░░░░░░░░░░░░░░░░░░]       |
|              |                                                             |
+--------------+-------------------------------------------------------------+
```

#### File-size handling

Count the UI screens from axis 2e:

- **≤ 10 screens** → emit all wireframes inline under `## Screens` in the inventory file.
- **> 10 screens** → emit one file per screen at `<projects_dir>/<name>/screens/<slug>.md` (slug from the route path or component name, kebab-case). The inventory's `## Screens` section becomes a linked index:

  ```markdown
  ## Screens

  > AI-inferred sketches — each linked file carries its own disclaimer.

  | # | Screen | Source | Wireframe |
  |---|--------|--------|-----------|
  | 1 | Login | `src/pages/LoginPage.jsx` | [screens/login.md](./screens/login.md) |
  | 2 | Orders list | `src/pages/OrdersPage.jsx` | [screens/orders.md](./screens/orders.md) |
  ```

  Each per-screen file has the disclaimer header at the top followed by the box.

The threshold is documented and overridable; see [`AgDR-0036`](../../../docs/agdr/AgDR-0036-inferred-mockups-honesty.md).

### 5. Save and report

Write `projects/<name>/feature-inventory.md`. If the file exists, prompt:

```
projects/<name>/feature-inventory.md already exists (last written {date}).
Overwrite? [y/N]
```

Default `N`. On `N`, write to `projects/<name>/feature-inventory-{YYYY-MM-DD}.md` and tell the user where the new file landed. The original is preserved.

Print a one-line summary on completion:

```
Feature inventory written: projects/<name>/feature-inventory.md
{N} features cataloged across {axes-with-findings}/6 axes.
{N} coverage gaps flagged. {N} recommended next steps.
```

When `--with-mockups` is set, append a second line:

```
ASCII wireframes emitted: {N} screen(s) {inline | under projects/<name>/screens/}.
All wireframes carry the AI-inferred disclaimer — verify before relying on.
```

## Why this skill exists

A greenfield rewrite that proceeds without a feature inventory has two common failure modes:

1. **Forgotten features** — the rewrite ships and a long-tail user files a bug because feature X wasn't ported. The team thought X was deprecated; it wasn't.
2. **Reverse-engineering during build** — every developer on the rewrite team spelunks the old codebase one route / one model at a time, duplicating work and producing inconsistent mental models.

The inventory is the single artefact that cuts both. It's not a spec, it's not a migration plan — it's a catalogue. The team negotiates trade-offs (drop / redesign / keep-as-is) against a known list, not against vibes.

## Anti-patterns

- **Don't auto-generate user stories from the matrix.** The inventory says "POST `/api/orders` exists"; only a human can decide it should become "As a customer, I want to place an order with one-click checkout". Translation is design work, not scanner work.
- **Don't size features.** The matrix lists features but does not estimate effort to rewrite each one. Sizing depends on target stack, team familiarity, and downstream dependencies — all out of scope here.
- **Don't run this every sprint.** It's a pre-rewrite scan, not a recurring audit. Run once, treat the artefact as a baseline, update only when the source codebase has changed substantially.
- **Don't substitute this for `/code-review` or `/launch-check`.** The inventory says what features exist; it doesn't say whether they're well-implemented, secure, or production-ready. Use the audit skills for quality signals.
- **Don't skip the human review step.** Prior-art bias is real — the matrix can feel authoritative even when it's missing 20% of the picture. Always reconcile with the previous owner / stakeholders before treating the inventory as canonical.
- **Don't strip the disclaimer header from `--with-mockups` wireframes.** The header is the trust contract for the artefact — the reader sees `AI-inferred sketch — verify before relying on` and treats it as a sketch. Without the header, an ASCII box looks more authoritative than it should. See [`AgDR-0036`](../../../docs/agdr/AgDR-0036-inferred-mockups-honesty.md).
- **Don't upgrade `--with-mockups` to PNG/SVG.** The format is ASCII by design — visual fidelity should match epistemic confidence. A pixel-perfect render of a model's guess at a screen is exactly the failure mode the flag was designed to avoid.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

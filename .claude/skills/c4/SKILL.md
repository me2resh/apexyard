---
name: c4
description: Generate C4 L1 (Context) + L2 (Container) Mermaid diagrams from a project's codebase. Structurizr DSL escape hatch (--dsl) for L3+ component precision.
argument-hint: "[project-name] [--level=1|2|both] [--force] [--dsl]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /c4 — Generate C4 Architecture Diagrams

Reads the target project's codebase and produces filled-in **Level 1 (System Context)** and **Level 2 (Container)** diagrams as Mermaid markdown. Saves the slog of filling in the templates by hand for a repo you already understand structurally.

This skill complements `/handover` (which seeds a *stub* L2 once at onboarding). Use `/c4` whenever the architecture changes substantially and the diagrams need a refresh — or for a project that wasn't onboarded via `/handover`.

For projects that hit Mermaid's ceiling — L3 (component) precision, auto-zoom across levels, tags/perspectives — pass `--dsl` to emit a **Structurizr DSL** workspace instead. See "Escape hatch: Structurizr DSL (L3+)" below.

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
/c4                                    # current cwd, both levels
/c4 curios-dog                         # registered project, both levels
/c4 curios-dog --level=1               # only the L1 system-context diagram
/c4 . --level=2                        # only the L2 container diagram for cwd
/c4 curios-dog --force                 # overwrite existing diagrams
/c4 curios-dog --dsl                   # Structurizr DSL escape hatch (L3+), instead of Mermaid
/c4 curios-dog --dsl --force           # overwrite an existing workspace.dsl
```

## Output location

Where the files land depends on **where the skill is invoked from** and **what argument is passed**:

| Invoked from | Arg | Output |
|---|---|---|
| `workspace/<name>/` (project clone) | none | `<project>/docs/architecture/{context,container}.md` (inside the project's own repo) |
| Ops fork root | `<name>` (registered project) | `projects/<name>/architecture/{context,container}.md` (ops view) |
| Ops fork root | none | `docs/architecture/{name}-{context,container}.md` (framework-wide) |
| Anywhere | `.` | Treat cwd as the project; write to `docs/architecture/{context,container}.md` |
| Any of the above | `--dsl` added | Same directory as the Mermaid output would use, but a single `workspace.dsl` file instead of `{context,container}.md` |

The split mirrors the existing convention from `docs/multi-project.md` § "Architecture diagrams".

## Process

### 1. Resolve the target

- If `<project-name>` is `.` → use cwd.
- If `<project-name>` is given and the registry has it → use `workspace/<name>/` if it exists, otherwise fall back to ops-view-only mode (no codebase to scan; ask the user to clone or to provide a path).
- If no arg → use cwd; if cwd is the ops fork root, ask whether the diagram is framework-wide or for a registered project.

If the cwd / target doesn't have any of the detection signals listed below (no `package.json`, no `Dockerfile`, no `template.yaml`, etc.), stop and tell the user — there's nothing to scan.

### 2. Detect

Run these in parallel; collect findings into a structured proposal.

#### 2a. Containers (L2)

A "container" in C4 is a **deployable / runnable unit** — a frontend, an API, a database, a queue, a worker, a CDN. Not a Docker container (confusing but standard).

Detection sources:

| Signal | Container inferred |
|---|---|
| `web/`, `frontend/`, `client/` with `package.json` | Web App (label by framework: detect Next.js / Vite / CRA from `dependencies`) |
| `backend/`, `api/`, `server/` with `package.json` | API |
| `admin/` with `package.json` | Admin App |
| Top-level `Dockerfile` (no monorepo split) | Single containerised service (label by base image) |
| `template.yaml` (SAM) | Each `AWS::Serverless::Function` → potentially a container, but **collapse to one logical "Lambda functions" container** unless there are clear domain boundaries (auth-functions vs api-functions). One box per domain, max 5–9 containers total. |
| `serverless.yml` | Same pattern as SAM — one container per logical service |
| Terraform module names (`infrastructure/modules/*`) | Each module that creates a runtime resource (DynamoDB, S3 bucket, CloudFront distribution, Cognito user pool, RDS instance) → infra container. **Skip pure-policy / pure-IAM modules.** |
| `prisma/schema.prisma` or migrations dir | Database container (label by `provider` in schema) |
| `package.json` deps containing `bullmq`, `bee-queue`, `agenda` | Background Worker container |
| `package.json` deps containing `@aws-sdk/client-s3`, `aws-sdk` (S3 usage) | S3 / object storage as a container if the project owns the bucket |
| Cron / EventBridge rules in IaC | Scheduler container |

Hard cap: **9 containers max**. If detection yields more, collapse the most-similar pair into a single container with a combined label, and surface the collapse to the user during step 3.

#### 2b. External actors and systems (L1)

External actors fall into three buckets — Person (humans), System_Ext (third-party SaaS / APIs), and the System (the box being modelled).

Detection sources:

| Signal | Actor type | Inferred name |
|---|---|---|
| Auth code present (Cognito / Auth0 / Clerk / Supabase Auth) | System_Ext | The auth provider |
| `@aws-sdk/client-bedrock`, `openai`, `@anthropic-ai/sdk` | System_Ext | The AI provider |
| `stripe`, `paddle`, `lemonsqueezy` | System_Ext | Payment processor |
| `posthog-js`, `@amplitude/analytics-browser`, `mixpanel-browser`, `react-ga4` | System_Ext | Analytics provider |
| `@sentry/*`, `@datadog/*`, `bugsnag-js` | System_Ext | Error / monitoring provider |
| `nodemailer`, `@sendgrid/mail`, `postmark`, `resend`, AWS SES use | System_Ext | Email provider |
| `twilio`, `vonage` | System_Ext | SMS / telephony |
| `algoliasearch`, `meilisearch`, `@elastic/elasticsearch` | System_Ext | Search provider |
| `dicebear`, image CDNs, fonts CDN (`fonts.googleapis.com`) | System_Ext | Asset CDN |
| Public-facing pages / `/[username]` style routes | Person | Public visitor |
| Admin routes (`/admin/`) | Person | Admin |
| Auth + non-admin routes | Person | End user |

If a signal could match multiple personas (e.g., the API serves both end users and admins), surface both; the user can collapse during confirm.

Detection should also pull the project's **one-sentence description** from:

- The README's first non-heading paragraph
- The `description` field in `package.json`
- An existing `projects/<name>/README.md` if the registry has the project

If none of those exist, ask the user for one sentence in step 3.

### 3. Confirm with the user

Show the detected proposal in a compact table:

```
For <project>:

External actors (L1):
  [Person] End user — uses the public profile pages
  [Person] Admin — manages reports and users
  [Ext] AWS Cognito — authentication
  [Ext] Amazon Bedrock — text embeddings for similarity
  [Ext] PostHog EU — product analytics
  [Ext] DiceBear — avatar generation

Containers (L2, inside the system boundary):
  Web App         Next.js 16        — public profile pages, sign-in, dashboard
  Backend API     AWS Lambda + SAM  — Q&A endpoints, profiles, likes, search
  Admin App       Next.js + Cognito — moderation console
  DynamoDB        single-table      — questions, answers, profiles, likes
  S3 (uploads)    public-read       — avatar + answer-attachment storage
  CloudFront      asset CDN         — public-asset distribution

One-sentence description:
  "Public Q&A platform — anonymous askers, public answers, share-driven growth."

Edit? (a) accept · (e) edit list · (d) edit description · (q) quit
>
```

On `e`: open an interactive add/remove flow — one item per prompt, accept by Enter, or type `add: <new item>` / `remove: <name>`.
On `d`: prompt for a one-sentence replacement description.
On `q`: exit without writing.
On `a`: proceed to step 4 (or step 4b if `--dsl` was passed).

### 4. Generate the Mermaid (skip if `--dsl` was passed — go to step 4b)

Resolve the C4 templates via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
context_template=$(portfolio_resolve_template architecture/c4-context.md)     # L1 skeleton
container_template=$(portfolio_resolve_template architecture/c4-container.md) # L2 skeleton
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/architecture/c4-{context,container}.md`. Adopters who want a customised C4 shape drop their versions at `<private_repo>/custom-templates/architecture/c4-{context,container}.md`. See `templates/README.md` for the path-mirroring convention.

Keep the surrounding markdown sections from the resolved templates ("How to use this template" can be trimmed in the generated file since these are real diagrams, not templates).

For **L1**:

```mermaid
C4Context
    title System Context for {Project Name}

    Person(<id>, "<Display>", "<Description>")
    ...
    System(main, "{Project Name}", "<one-sentence description>")
    System_Ext(<id>, "<Name>", "<Tech / role>")
    ...
    Rel(<from>, <to>, "<Verb>", "<Protocol>")
    ...
```

For **L2**:

```mermaid
C4Container
    title Container Diagram for {Project Name}

    Person(<id>, "<Display>", "<Description>")
    ...
    System_Boundary(boundary, "{Project Name}") {
        Container(<id>, "<Name>", "<Tech>", "<Responsibility>")
        ContainerDb(<id>, "<Name>", "<Tech>", "<What it stores>")
    }
    System_Ext(<id>, "<Name>", "<Tech>")
    ...
    Rel(<from>, <to>, "<Verb>", "<Protocol>")
    ...
```

**Relationship inference rules**:

- `Person` → primary `Container` (Web / API) over HTTPS
- `Web` → `API` over HTTPS / JSON
- `API` → `ContainerDb` over the DB protocol (SQL / DynamoDB / etc.)
- `API` → `System_Ext` over the integration protocol (OAuth / HTTPS / SMTP)
- `Worker` → `Queue` if a queue is detected
- All `System_Ext` arrows point **outward** from the system boundary

Don't over-annotate. If a relationship is obvious ("Web calls API"), keep the verb to one word.

### 4b. Generate the Structurizr DSL (`--dsl` only)

Reuse the **same detected model** from step 2 (containers, external actors, relationships) — the DSL escape hatch does not re-run detection, it re-renders the same proposal the user already confirmed in step 3 into a different output format. See "Escape hatch: Structurizr DSL (L3+)" below for the full mapping and the L3 (component) authoring note.

Resolve the template the same way as step 4:

```bash
dsl_template=$(portfolio_resolve_template architecture/c4-structurizr.dsl)
```

Falls through to `templates/architecture/c4-structurizr.dsl` for adopters with no override. Adopter overrides live at `<private_repo>/custom-templates/architecture/c4-structurizr.dsl` (same path-mirroring convention as the Mermaid templates).

### 5. Write the files

Path resolution from step 1's table (or its `--dsl` row). Behaviour:

- If the file does **not** exist → write directly.
- If the file **does** exist:
  - Without `--force`: stop, print a diff against the proposed content, ask the user to either re-run with `--force` or merge by hand.
  - With `--force`: overwrite. Print a diff so the user sees what changed.

Each generated Mermaid file ends with a small footer:

```markdown
---

_Generated by `/c4` on YYYY-MM-DD. Re-run after architecture changes._
```

The generated `workspace.dsl` ends with the DSL-comment equivalent:

```
// Generated by /c4 --dsl on YYYY-MM-DD. Re-run after architecture changes.
```

This is the skill's signature — readers know it's regenerable, not hand-maintained.

### 6. Lint the generated output

**Mermaid** (skip if `--dsl`): run `lint.sh` against each file written in step 5. The lint wraps the shared `_lib-mermaid-lint.sh` — extracts every `` ```mermaid `` block and validates each via `mmdc` (mermaid-cli) so broken syntax is caught at write time, not when a human opens the file on GitHub. Graceful-degrades when Node / npx is unavailable (exit 3, advisory only; doesn't block the skill).

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/lint.sh" "$context_out" || lint_rc=$?
"$SKILL_DIR/lint.sh" "$container_out" || lint_rc=$?
```

Treat exit 1 (parse error) as a hard fail — print the lint output, ask the operator whether to (a) auto-regenerate the offending block, (b) keep the file as-is and fix by hand, or (c) re-run with `--skip-lint` if mmdc is misbehaving. Exit 3 (Node missing) prints a one-line warning and proceeds.

**Structurizr DSL** (`--dsl` only): run `lint-dsl.sh` against the written `workspace.dsl`. The lint wraps the shared `_lib-structurizr-lint.sh` — a **structural** check (balanced braces, `workspace`/`model`/`views` blocks present, no duplicate identifiers), not a full DSL parse, because the escape hatch is dependency-free by design (no Java, no Docker required). If `structurizr-cli` happens to be on the adopter's PATH, the lint also runs a real parse via it — a bonus, never a requirement.

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/lint-dsl.sh" "$dsl_out" || lint_rc=$?
```

Same exit-code contract as `lint.sh`: 1 is a hard fail (print, ask), 2 is bad input, `--skip-lint` bypasses.

### 7. Confirm to the user

Mermaid mode:

```
✓ <project>: C4 diagrams written

  L1: <path/to/context.md>
  L2: <path/to/container.md>

  Containers: 6 (max 9)
  External: 6 systems, 2 actors
  Mermaid lint: 2 of 2 files parsed cleanly

Preview: open the file on GitHub — Mermaid renders inline.
Re-run /c4 <project> --force when the architecture changes.
```

`--dsl` mode:

```
✓ <project>: Structurizr DSL workspace written

  DSL: <path/to/workspace.dsl>

  Containers: 6 (max 9, but --dsl has no cap — L3 detail lives inside them)
  External: 6 systems, 2 actors
  Structural lint: OK (structurizr-cli not found — structural-only; render to verify visually)

Render: paste the file at https://structurizr.com/dsl (free, zero install),
  or install structurizr-cli / run Structurizr Lite if you want a local
  render step. See "Escape hatch: Structurizr DSL (L3+)" below.
Re-run /c4 <project> --dsl --force when the architecture changes.
```

## Escape hatch: Structurizr DSL (L3+)

Mermaid stays the **default** — nothing above changes for a plain `/c4` invocation. `--dsl` is a side-channel for projects that hit a real wall, not a migration. Decision rationale: [`AgDR-0085`](../../../docs/agdr/AgDR-0085-structurizr-dsl-escape-hatch.md) (a follow-up to the original tool choice in [`AgDR-0003`](../../../docs/agdr/AgDR-0003-mermaid-c4-for-diagrams.md), which explicitly deferred this).

### When to reach for `--dsl`

| Signal | Why Mermaid falls short |
|---|---|
| You need **L3 (component) precision** inside a container | Mermaid's C4 support stops cleanly at L2; component-level diagrams get unwieldy fast |
| You want **auto-zoom** from one model to L1 → L2 → L3 | Mermaid requires hand-maintained, independently-drifting L1/L2/L3 files; Structurizr renders all views from one `model { }` block |
| You need **tags, per-view styling, or filtered views** | Structurizr Workspace features Mermaid's C4 beta doesn't have |
| A container is genuinely pushing past the 9-container L2 cap because it needs component-level breakdown, not because the system itself has 10+ deployable units | That's an L3 problem wearing an L2 costume — `--dsl` is the right fix, not further collapsing |

If none of those apply, stay on plain `/c4` — Mermaid's zero-install, renders-on-GitHub property is still the better default for L1/L2.

### What `--dsl` generates

One `workspace.dsl` file (Structurizr's canonical extension) capturing:

- `model { }` — the same `person` / `softwareSystem` / `container` entries the Mermaid path would generate from steps 2–3, PLUS optional `component { }` blocks nested inside a `container` for the L3 detail Mermaid can't express
- `views { }` — a `systemContext`, a `container`, and (for any container you added components to) a `component` view — all `autoLayout`, all from the one model
- A `styles { }` block distinguishing `Person`, `External` (softwareSystem outside the boundary), and `Database` (container/component tagged `"Database"`) shapes/colors

**L3 components are not auto-detected.** Step 2's detection (this skill's core value) stops at L2 — inferring components from source would mean parsing call graphs, which is a materially bigger feature than this escape hatch. The generated `workspace.dsl` gives you the L1 + L2 model auto-filled exactly like the Mermaid path, with the L3 `component { }` blocks present as a **worked example inside the template** (see `templates/architecture/c4-structurizr.dsl`) for you to extend by hand into whichever container needs the precision.

### Rendering the DSL

No render step is required to get value from the file — `workspace.dsl` is readable as text, and the escape hatch's whole design point (AgDR-0085) is that it introduces **no new runtime dependency** to the framework. When you do want to see the diagram:

| Option | Install | Notes |
|---|---|---|
| **[structurizr.com/dsl](https://structurizr.com/dsl)** | None | Paste the file, view instantly. Free. Zero install — the recommended default. |
| **Structurizr Lite (Docker)** | Docker | `docker run -it --rm -p 8080:8080 -v $PWD:/usr/local/structurizr structurizr/lite` then open `localhost:8080`. Good for a local/offline loop. |
| **`structurizr-cli export`** | Java | `structurizr-cli export -workspace workspace.dsl -format plantuml` (or `mermaid`, `png`, `svg`, …). If it's on PATH, `/c4 --dsl`'s lint step (6) uses it automatically for a real parse, not just the structural check. |

None of these are required by the framework itself — they're the adopter's choice at render time, same as choosing which Markdown viewer to read a `.md` file in.

### Relationship to the Mermaid path

`--dsl` reuses steps 1–3 (resolve, detect, confirm) unchanged — the detection logic and the user-facing confirmation table are identical whether you're about to render Mermaid or DSL. Only step 4 (generation) and everything downstream branches. This keeps the two output modes from drifting into two different detection engines.

## Rules

1. **Read-only against the codebase** — never modify the project's source. Only writes to the architecture-doc paths in step 5.
2. **Never auto-overwrite** — existing diagrams require explicit `--force`. The diagrams may have been hand-edited; clobbering them silently is the worst-case failure. Applies to `workspace.dsl` exactly like the Mermaid files.
3. **Hard cap at 9 containers (Mermaid path only)** — collapse before showing the user, never produce a Mermaid diagram with 10+ boxes. If a project genuinely needs more container-level detail, that's a signal to reach for `--dsl` and add L3 `component { }` blocks instead of further collapsing L2. The `--dsl` path itself has no hard container cap — L3 detail is where the extra precision belongs.
4. **Don't invent integrations** — every `System_Ext` / `softwareSystem "..." "External"` must be backed by a concrete signal in step 2. If you saw `nodemailer` in `package.json`, you can list "Email provider"; if you didn't, you can't list "Email provider" because most apps eventually need one.
5. **One-sentence description is required** — if no source supplies one, ask the user. Never ship a diagram with a placeholder system description like "what the system does".
6. **Trim the template's "How to use this template" section** in the generated output — that's instructional copy for the templates, not for filled-in diagrams. (The DSL template's leading `//` header comment is the DSL-equivalent instructional copy — trim the same way.)
7. **Footer signature is mandatory** — every generated file ends with the `Generated by /c4 on YYYY-MM-DD` line (or its `//`-comment DSL equivalent) so future readers know it's regenerable.
8. **Refuse if there's nothing to scan** — no `package.json`, no IaC, no Dockerfile, no `src/` → stop with an error rather than producing an empty diagram. Applies regardless of `--dsl`.
9. **`--dsl` never introduces a runtime dependency** — the generation and lint (step 6) paths must work with nothing beyond Bash/awk/grep installed. `structurizr-cli` / Docker / the online editor are adopter-chosen render-time tools, never a framework requirement.

## When to use this

| Trigger | Use `/c4`? |
|---------|------------|
| Setting up architecture docs for a project that wasn't onboarded via `/handover` | Yes |
| Refreshing diagrams after a major architecture change (new container, dropped third party) | Yes — use `--force` |
| Onboarding a new external repo | Use `/handover` first (it seeds a stub); then `/c4 --force` once you've understood the codebase |
| A project needs L3 (component) precision or auto-zoom across levels | Yes — `/c4 <project> --dsl` |
| Drawing a sequence diagram or per-class diagram | No — that's `/dfd` or a hand-authored diagram; `/c4` (Mermaid or `--dsl`) covers L1/L2/L3, not sequence flows |
| Showing a multi-system view (apexscript + curios-dog on one canvas) | No — one project per invocation. Multi-system diagrams are a separate concern |

## Out of scope (v1)

- **L4 (Code)** — premature for typical use even with the `--dsl` escape hatch; teams that need it know they need it
- **Auto-detected L3 components** — `--dsl` gives you the model and the view, not automated component inference from source; see "What `--dsl` generates" above
- **Auto-diff against existing diagrams** — `--force` is the v1 escape hatch for both Mermaid and DSL; smarter merging is a separate skill if it proves needed
- **Multi-system canvases** — single-system per invocation
- **Auto-PR creation** — the skill writes files; the user commits via the normal PR flow (apexyard hooks ensure that)
- **Sequence / deployment / data-flow diagrams** — different DSLs, different audiences, different skills if needed
- **Bundling a Structurizr renderer or shelling out to one by default** — the framework never installs Java/Docker on the adopter's behalf; rendering is always the adopter's explicit, separate choice

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

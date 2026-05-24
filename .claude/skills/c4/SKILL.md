---
name: c4
description: Generate C4 L1 (Context) + L2 (Container) Mermaid diagrams from a project's codebase.
argument-hint: "[project-name] [--level=1|2|both] [--force]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /c4 — Generate C4 Architecture Diagrams

Reads the target project's codebase and produces filled-in **Level 1 (System Context)** and **Level 2 (Container)** diagrams as Mermaid markdown. Saves the slog of filling in the templates by hand for a repo you already understand structurally.

This skill complements `/handover` (which seeds a *stub* L2 once at onboarding). Use `/c4` whenever the architecture changes substantially and the diagrams need a refresh — or for a project that wasn't onboarded via `/handover`.

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
```

## Output location

Where the files land depends on **where the skill is invoked from** and **what argument is passed**:

| Invoked from | Arg | Output |
|---|---|---|
| `workspace/<name>/` (project clone) | none | `<project>/docs/architecture/{context,container}.md` (inside the project's own repo) |
| Ops fork root | `<name>` (registered project) | `projects/<name>/architecture/{context,container}.md` (ops view) |
| Ops fork root | none | `docs/architecture/{name}-{context,container}.md` (framework-wide) |
| Anywhere | `.` | Treat cwd as the project; write to `docs/architecture/{context,container}.md` |

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
On `a`: proceed to step 4.

### 4. Generate the Mermaid

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

### 5. Write the files

Path resolution from step 1's table. Behaviour:

- If the file does **not** exist → write directly.
- If the file **does** exist:
  - Without `--force`: stop, print a diff against the proposed content, ask the user to either re-run with `--force` or merge by hand.
  - With `--force`: overwrite. Print a diff so the user sees what changed.

Each generated file ends with a small footer:

```markdown
---

_Generated by `/c4` on YYYY-MM-DD. Re-run after architecture changes._
```

This is the skill's signature — readers know it's regenerable, not hand-maintained.

### 6. Lint the generated Mermaid

Run `lint.sh` against each file written in step 5. The lint wraps the shared `_lib-mermaid-lint.sh` — extracts every `` ```mermaid `` block and validates each via `mmdc` (mermaid-cli) so broken syntax is caught at write time, not when a human opens the file on GitHub. Graceful-degrades when Node / npx is unavailable (exit 3, advisory only; doesn't block the skill).

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/lint.sh" "$context_out" || lint_rc=$?
"$SKILL_DIR/lint.sh" "$container_out" || lint_rc=$?
```

Treat exit 1 (parse error) as a hard fail — print the lint output, ask the operator whether to (a) auto-regenerate the offending block, (b) keep the file as-is and fix by hand, or (c) re-run with `--skip-lint` if mmdc is misbehaving. Exit 3 (Node missing) prints a one-line warning and proceeds.

### 7. Confirm to the user

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

## Rules

1. **Read-only against the codebase** — never modify the project's source. Only writes to the architecture-doc paths in step 5.
2. **Never auto-overwrite** — existing diagrams require explicit `--force`. The diagrams may have been hand-edited; clobbering them silently is the worst-case failure.
3. **Hard cap at 9 containers** — collapse before showing the user, never produce a diagram with 10+ boxes. If a project genuinely needs more than 9, that's an L3 (Component) diagram, which is out of scope for v1.
4. **Don't invent integrations** — every `System_Ext` must be backed by a concrete signal in step 2. If you saw `nodemailer` in `package.json`, you can list "Email provider"; if you didn't, you can't list "Email provider" because most apps eventually need one.
5. **One-sentence description is required** — if no source supplies one, ask the user. Never ship a diagram with a placeholder system description like "what the system does".
6. **Trim the template's "How to use this template" section** in the generated output — that's instructional copy for the templates, not for filled-in diagrams.
7. **Footer signature is mandatory** — every generated file ends with the `Generated by /c4 on YYYY-MM-DD` line so future readers know it's regenerable.
8. **Refuse if there's nothing to scan** — no `package.json`, no IaC, no Dockerfile, no `src/` → stop with an error rather than producing an empty diagram.

## When to use this

| Trigger | Use `/c4`? |
|---------|------------|
| Setting up architecture docs for a project that wasn't onboarded via `/handover` | Yes |
| Refreshing diagrams after a major architecture change (new container, dropped third party) | Yes — use `--force` |
| Onboarding a new external repo | Use `/handover` first (it seeds a stub); then `/c4 --force` once you've understood the codebase |
| Drawing a sequence diagram or per-class diagram | No — `/c4` only does L1 + L2. L3/L4 are deferred (often overkill anyway) |
| Showing a multi-system view (apexscript + curios-dog on one canvas) | No — one project per invocation. Multi-system diagrams are a separate concern |

## Out of scope (v1)

- **L3 (Component)** and **L4 (Code)** — premature for typical use; teams that need them know they need them
- **Auto-diff against existing diagrams** — `--force` is the v1 escape hatch; smarter merging is a separate skill if it proves needed
- **Multi-system canvases** — single-system per invocation
- **Auto-PR creation** — the skill writes files; the user commits via the normal PR flow (apexyard hooks ensure that)
- **Sequence / deployment / data-flow diagrams** — different DSLs, different audiences, different skills if needed

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

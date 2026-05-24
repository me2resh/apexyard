---
name: dfd
description: DFD with trust boundaries + data classifications (Mermaid + optional Threat Dragon JSON). Source-of-truth for /threat-model.
argument-hint: "[project-name | . | --scope-all] [--format=mermaid|dragon|all]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /dfd — Data Flow Diagram Extractor

Reads a codebase (or a portfolio of codebases for system-wide DFDs) and produces a Data Flow Diagram showing external actors, processes, data stores, data flows, trust boundaries, and per-element data classifications. The DFD is the **input to STRIDE threat modelling** and to GDPR cross-border / DPA-coverage analysis.

This skill is the **canonical DFD producer** in the apexyard family. `/threat-model` and `/compliance-check` consume the DFD it writes instead of regenerating their own — see AgDR-0026 for the design rationale.

| Skill | Role |
|-------|------|
| `/dfd` (this skill) | Produces the DFD — six-axis discovery + classifications + cross-repo trace |
| `/threat-model` | Consumes the DFD — STRIDE walk over each trust-boundary crossing |
| `/compliance-check` | Consumes the DFD's classifications — cross-border transfers + DPA coverage |
| `/c4` | Static topology (different shape — system + containers, no data-flow semantics) |
| `/process` (#256) | Dynamic control flow — BPMN, anchor-scoped multi-repo trace (shares the `_lib-multi-repo-trace.sh` helper) |

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the workspace dir via `portfolio_workspace_dir` from `.claude/hooks/_lib-portfolio-paths.sh`. Cross-repo discovery uses the shared `_lib-multi-repo-trace.sh` helper. Source both at the top of any bash block:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-multi-repo-trace.sh"
projects_dir=$(portfolio_projects_dir)
```

Defaults match today's single-fork layout. Adopters in split-portfolio mode override the `portfolio.*` keys in `.claude/project-config.json` — the helper resolves whichever mode they're in. See `docs/multi-project.md`.

## Usage

```
/dfd                                   # interactive — asks for scope (single service or system-wide)
/dfd billing-api                       # registered project — single-service DFD
/dfd .                                  # treat cwd as the project root
/dfd --scope-all                       # walk the whole registry — system-wide DFD with per-service sub-models
/dfd billing-api --format=dragon       # also emit Threat Dragon v2 JSON
/dfd billing-api --format=all          # Mermaid + Threat Dragon + (future) PlantUML
```

Re-running on the same scope OFFERS (default-no) to overwrite — same UX as `/extract-features` and `/c4`. Existing edits are preserved unless the operator explicitly accepts.

## Output location

```
projects/<project-name>/architecture/dfd.md            ← Mermaid markdown (primary, source of truth)
projects/<project-name>/architecture/dfd.json          ← Threat Dragon v2 JSON (on --format=dragon)
projects/<project-name>/architecture/dfd-source.yaml   ← discovery report — supports "what changed since last run"
```

For `--scope-all`:

```
docs/architecture/system-dfd.md                        ← composed system-wide DFD
docs/architecture/system-dfd-source.yaml               ← per-service discovery reports concatenated
```

## Process

### 1. Resolve the target + scope

- If the argument is `.` → use cwd as the target.
- If the argument names a registered project → resolve to `workspace/<name>/`. If the workspace clone doesn't exist, stop and ask the operator to clone first (do not auto-clone — same convention as `/handover` and `/extract-features`).
- If no argument and cwd is inside `workspace/<name>/` → use that project.
- If no argument and cwd is the ops fork root → ask: *"Scope this DFD to one service, or the whole system?"*
- If `--scope-all` → walk every registered project; each becomes a trust-boundary box in the composed system DFD.

### 2. Run the six-axis discovery (read-only)

Discovery is anchored on the target and reachability-bounded. **No files written until the operator approves the candidate model.**

| Axis | What | How |
|------|------|-----|
| **1. External actors** | Users, auth providers, third-party SaaS, admin consoles | HTTP route scope (anonymous / authenticated / admin); SDK imports (`stripe`, `@sendgrid/mail`, `@anthropic-ai/sdk`); auth provider imports (`@auth0`, `@clerk/`, Cognito); webhook signature handlers |
| **2. Processes** | HTTP handlers, queue consumers, scheduled jobs, message-broker subscribers, gRPC methods | Framework signatures (Express / Fastify / NestJS / FastAPI / Flask / Django / Rails / Gin / Spring / Lambda); job-framework signatures (BullMQ, Celery, Sidekiq, Active Job, Temporal); cron / EventBridge schedules |
| **3. Data stores** | RDBMSes, document stores, caches, object storage, file systems, data warehouses, search indexes | Schema files (`schema.prisma`, `models.py`, `*.rb` Active Record, `*.sql` migrations); SDK imports (`@aws-sdk/client-*`, `ioredis`, `mongoose`); connection-string env vars |
| **4. Data flows** | What crosses what — payload + arrow direction | Reachability — handler reads/writes which store, calls which external API, enqueues to which worker. LSP-aware path uses call-graph; grep fallback uses imports + usage co-location |
| **5. Trust boundaries** | Network / auth / org / classification boundaries | Inferred from code + env config: public ↔ backend (HTTP scope), backend ↔ data (DB credentials gating), user ↔ admin (route prefix), us ↔ third-party (external SDKs). **Note**: IaC reading is out of scope for v1 |
| **6. Data classifications** | PII, PCI, secrets, internal, public — per detected element | Three pathways: code annotations (`@PII`, `// CLASSIFIED: <label>`), env-var heuristics (`*_SECRET`, `*_TOKEN`), schema-column heuristics (`email`, `phone`, `card_number`). Optional explicit registry at `docs/data-classification.{md,yaml}` overrides heuristics |

The grep-fallback signatures live in `.claude/skills/dfd/discover.sh` (axes 1–5) and `.claude/skills/dfd/classify.sh` (axis 6). When LSP is enabled (`ENABLE_LSP_TOOL=1` + per-language plugin per `docs/getting-started.md`), the skill prefers semantic-index queries over grep for axes 1, 2, 3, and 4. Discovery is identical in shape; LSP just makes it cheaper.

For `--scope-all`: run axes 1–6 against each registered project, then in step 3 compose by treating every cross-service flow (detected via `_lib-multi-repo-trace.sh`) as a trust-boundary crossing.

### 3. Present the candidate model for operator review

Render the discovery output in a compact table grouped by axis:

```
For billing-api:

External actors:
  [Human]   Authenticated customer — POST /api/charges
  [Human]   Admin — /admin/* routes
  [Ext SaaS] Stripe — payment processing (charges, customers)
  [Ext SaaS] SendGrid — transactional email
  [Ext]     Auth0 — authentication provider

Processes:
  HTTP API (12 routes)
  Webhook handler (Stripe callbacks)
  Background workers (2 BullMQ queues: email, reconciliation)
  Scheduled jobs (1: nightly reconciliation)

Data stores:
  Postgres (via Prisma) — primary data store
  Redis — session cache + queue backend
  S3 — invoice PDF storage

Inferred trust boundaries:
  Public Internet ↔ Backend (HTTP scope)
  Backend ↔ Data Stores (DB credentials)
  User ↔ Admin (privilege escalation on /admin/*)
  Us ↔ Stripe (org boundary, signed webhooks)
  Us ↔ SendGrid (org boundary)

Data classifications (detected):
  user.email                          [PII]    via schema column     — prisma/schema.prisma:42
  user.phone_number                   [PII]    via schema column     — prisma/schema.prisma:44
  charge.card_number                  [PCI]    via schema column     — prisma/schema.prisma:118
  STRIPE_SECRET_KEY                   [secrets] via env-var heuristic — .env.example:3
  SENDGRID_API_KEY                    [secrets] via env-var heuristic — .env.example:5
  user.profile @PII                   [pii]    via annotation         — src/models/user.ts:12

(d) describe in more detail
(e) edit the model (add/remove element, change classification, reword trust boundary)
(a) accept and generate the diagram
(q) quit without writing
>
```

### 4. Interview — gap-fill only

Ask the operator ONLY where the code is silent:

- *"this field `user.identifier` — is this an email, a UUID, or something else? Classification?"*
- *"placing a trust boundary between the public API gateway and the internal services — confirm or override?"*
- *"any human admin actors who interact via a console / runbook outside this codebase?"*
- *"the `messaging` queue — is the consumer in this repo, or in another registered service?"* (only when cross-repo traversal is ambiguous)

Don't ask questions whose answer is already in the discovery report.

### 5. Generate the output(s)

Resolve the template:

```bash
template=$(portfolio_resolve_template architecture/dfd.md)
```

Single-fork adopters with no override fall through to `templates/architecture/dfd.md`. Adopters who want a customised shape drop their version at `<private_repo>/custom-templates/architecture/dfd.md` (same convention as `/c4`).

#### 5a. Mermaid markdown (always)

Build the in-memory DFD model (actors / processes / stores / flows / boundaries / classifications) from the approved candidate. Pipe through `generate-mermaid.sh` to assemble the markdown file:

```bash
discovery_yaml="/tmp/dfd-discovery-${PROJECT}.yaml"
classifications_yaml="/tmp/dfd-classifications-${PROJECT}.yaml"

bash .claude/skills/dfd/discover.sh "$target_dir" "$scope_hint"   > "$discovery_yaml"
bash .claude/skills/dfd/classify.sh "$target_dir"                 > "$classifications_yaml"

bash .claude/skills/dfd/generate-mermaid.sh "$PROJECT" "$discovery_yaml" "$classifications_yaml" \
  > "projects/${PROJECT}/architecture/dfd.md"

# Persist the source-of-truth combined report for re-run diffs
cat "$discovery_yaml" "$classifications_yaml" > "projects/${PROJECT}/architecture/dfd-source.yaml"
```

The generator replaces placeholders in the template skeleton with real actors / processes / stores / flows from the in-memory model. Every cross-boundary arrow MUST carry a payload label.

#### 5b. Threat Dragon v2 JSON (on `--format=dragon` or `--format=all`)

Build a JSON document with the in-memory model and pipe through `generate-dragon.sh`:

```bash
echo "$model_json" \
  | bash .claude/skills/dfd/generate-dragon.sh \
  > "projects/${PROJECT}/architecture/dfd.json"
```

`generate-dragon.sh` is a **pure function over the in-memory model** — `/threat-model --format=dragon` (#255) will import the same serialiser when it lands. If `#255` ships first with the serialiser inside `/threat-model`, switch this skill to import from there during code review.

Schema reference: [OWASP Threat Dragon repository](https://github.com/OWASP/threat-dragon) (see `td.vue/src/service/migration/schema/` for the published v2 JSON schema).

#### 5c. Cross-repo composition (on `--scope-all`)

### Mermaid lint gate (after every write)

After every `dfd.md` write, run `lint.sh` against the output file. The lint wraps the shared `_lib-mermaid-lint.sh` — extracts the `` ```mermaid `` flowchart block and validates via `mmdc` so broken trust-boundary diagrams are caught at write time, not when a human opens the file on GitHub. Graceful-degrades when Node / npx is unavailable (exit 3, advisory only).

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/lint.sh" "$dfd_out" || lint_rc=$?
```

Exit 1 (parse error) → print the lint output and ask the operator whether to regenerate the diagram block, fix by hand, or re-run with `--skip-lint`. Exit 3 (Node missing) → one-line warning, proceed.

---

For each registered project, run discovery → render per-service sub-model. Compose by:

1. Each service becomes a **dashed trust-boundary subgraph** in the composed Mermaid
2. Every cross-service flow (detected via `mrt_resolve_target` from `_lib-multi-repo-trace.sh`) becomes an arrow crossing the boundary
3. Unmanaged third parties (Stripe, SendGrid, Salesforce — detected via `mrt_is_third_party`) render as external entities with their own trust-boundary marker
4. Each cross-repo handoff is labelled with the broker + topic / endpoint URL / etc.

Output lands at `docs/architecture/system-dfd.md` (framework-wide view).

### 6. Re-run UX + drift detection

If `projects/<name>/architecture/dfd.md` already exists, prompt:

```
projects/<name>/architecture/dfd.md already exists (last written {date}).
Overwrite? [y/N]
```

Default `N`. On `N`: write to `projects/<name>/architecture/dfd-{YYYY-MM-DD}.md` so the operator can diff old vs new. On `y`: overwrite, BUT first diff the new `dfd-source.yaml` against the previous one and surface a "what changed" summary:

```
DFD drift since last run:
  + new data store: docdb_dynamo (./src/billing/audit-log.ts:14)
  + new external service: ext_twilio (./src/notifications/sms.ts:8)
  + new flow: http_api → ext_twilio
  + new classification: phone_number [pii] (./prisma/schema.prisma:44)

These changes may warrant a fresh /threat-model run — newly-introduced data flows
are exactly the surface security review should focus on.
```

### 7. Index in `architecture/README.md`

If `projects/<name>/architecture/README.md` exists, ensure it lists the DFD alongside any C4 diagrams. If it doesn't exist, create it with a minimal index:

```markdown
# {project-name} — Architecture

| Diagram | Source | Last generated |
|---------|--------|----------------|
| [System Context (C4 L1)](./context.md) | `/c4 {project} --level=1` | YYYY-MM-DD |
| [Container (C4 L2)](./container.md) | `/c4 {project} --level=2` | YYYY-MM-DD |
| [Data Flow Diagram](./dfd.md) | `/dfd {project}` | YYYY-MM-DD |
```

### 8. Final confirmation

```
✓ {project}: DFD written

  Mermaid: projects/{project}/architecture/dfd.md
  Source:  projects/{project}/architecture/dfd-source.yaml
  {Dragon JSON: projects/{project}/architecture/dfd.json}

  Actors: {N actors}    Processes: {N}    Stores: {N}    Flows: {N}    Boundaries: {N}
  Classifications: {N PII} / {N PCI} / {N secrets} / {N other}

Source of truth: /threat-model and /compliance-check now read from this file.
Re-run /dfd {project} after architecture changes.
```

## Worked example

Run `/dfd billing-api` against a small Express + Prisma + BullMQ service that integrates with Stripe + SendGrid:

**Discovery** picks up:

- HTTP routes (12) → public_user actor + http_api process + public ↔ backend boundary
- `@auth0` import → auth0 external actor
- `stripe`, `@sendgrid/mail` imports → stripe + sendgrid external actors + us ↔ third-party boundary
- `prisma/schema.prisma` → postgres data store + backend ↔ data boundary
- `ioredis` import → redis cache
- `bullmq` `new Worker(` → background-worker process
- `cron.schedule(` → scheduled-job process

**Classifications** detect:

- `user.email` (Prisma column) → PII
- `user.phone_number` (Prisma column) → PII
- `card_number` (mentioned in Stripe-flow code) → PCI
- `STRIPE_SECRET_KEY` (env var) → secrets
- `SENDGRID_API_KEY` (env var) → secrets

**Operator review** confirms the model, classifies one ambiguous `user.identifier` as PII (UUID, but used as a join key), and overrides the trust boundary between worker and Stripe to also include the email worker (single "outbound integrations" boundary).

**Output**: `projects/billing-api/architecture/dfd.md` with the Mermaid diagram, trust-boundaries table, classifications table, and full provenance YAML. Subsequent `/threat-model billing-api` reads from this file and produces the STRIDE catalogue against the boundary crossings — no DFD regeneration.

## Rules

1. **Read-only against the codebase.** Never modify the project's source. Only writes to `projects/<name>/architecture/`.
2. **Read-first, ask-later.** The discovery report comes BEFORE any operator question. Don't ask things the code already says.
3. **Default-no on overwrite.** Existing DFDs may have been hand-edited; clobbering them silently is the worst-case failure. The drift summary (step 6) makes accepted overwrites informative.
4. **Reachability-bounded.** A single-service DFD walks only what's connected to that service. Don't expand to the whole registry unless `--scope-all`.
5. **Three classification pathways are additive, the explicit registry wins.** If `docs/data-classification.{md,yaml}` exists, its labels override heuristic labels for any field it covers.
6. **Don't invent third-party integrations.** Every `External Service` actor must trace to a concrete SDK import, API key env var, or webhook handler. No guessing.
7. **Footer signature is mandatory.** Every generated `dfd.md` ends with `Generated by /dfd on YYYY-MM-DD` so re-runners know the file is regenerable.
8. **Refuse if there's nothing to scan.** No `package.json`, no `pyproject.toml`, no `Gemfile`, no schema → stop with an error rather than producing an empty DFD.
9. **The live DFD evolves freely (#270).** `/threat-model` and `/compliance-check` snapshot this DFD into their own outputs at audit time — they read the file once and inline the Mermaid + trust-boundaries + classifications sections into the audit artefact. So editing this file does **not** invalidate previously-written audits; their snapshots are frozen in time. Re-run the audit to refresh against the current DFD.

## When to use this

| Trigger | Use `/dfd`? |
|---------|-------------|
| Preparing for a security review | YES — produces the DFD `/threat-model` needs |
| Preparing for GDPR / ePrivacy launch check | YES — produces the classifications `/compliance-check` needs |
| Adopting a new project via `/handover` | OFFER after `/c4` — sequence: `/handover` → `/c4` (static topology) → `/dfd` (data flows) → `/threat-model` (security analysis) |
| Major architecture change (new DB, new third party) | YES — re-run; the drift summary surfaces the delta |
| Pure UI / styling work | NO — no data-flow change, DFD stable |
| Spike / throwaway POC | NO — the surface isn't stable enough to be worth modelling |

## Out of scope (v1)

- **IaC reading** (Terraform / CloudFormation / SAM) for trust-boundary inference — code + env config only in v1
- **SAST / DAST substitution** — `/dfd` informs threat modelling and compliance, doesn't substitute for actual security scans
- **Pretty SVG/PNG export** — Threat Dragon does that after JSON import
- **PlantUML DFD format** (`--format=plantuml-dfd`) — listed in the AC as v2 follow-up
- **Round-trip import** — hand-edited `dfd.md` → re-parsed back into discovery model
- **Continuous / real-time DFD updates** — one-shot, same as siblings
- **L3 / L4 detail** — single DFD per scope; per-service component-level DFDs are out-of-scope (use multiple `/dfd <subscope>` runs if needed)

## Anti-patterns

- **Don't substitute `/dfd` for security review.** The DFD is the input to STRIDE, not the threat model itself. Always pair with `/threat-model` for the actual security analysis.
- **Don't run `/dfd --scope-all` on every PR.** It's a one-off baseline + on-significant-change refresh. Single-service `/dfd` is the per-PR cadence.
- **Don't classify by guessing.** If neither the annotation, env-var, schema, nor explicit-registry pathways fire on a field, leave it unclassified and surface in coverage gaps. False classifications are worse than missing ones (they create false confidence in compliance output).
- **Don't skip the operator review step.** Heuristic discovery has false positives; the operator's "yes, those are real boundaries; no, that field is not PII" pass is load-bearing for downstream consumers.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

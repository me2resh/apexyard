---
name: process
description: Extract a business process from registered repos via 7-axis code scan + gap-targeted interview, then emit lint-clean BPMN 2.0.
argument-hint: "<process-slug> [--from-endpoint METHOD /path] [--from-machine ClassName] [--from-job JobName] [--scope dir/] [--project name] [--pools] [--swimlanes] [--skip-lint] [--force]"
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /process: BPMN 2.0 from Code, Anchor-Scoped, Cross-Repo-Aware

Map a named business process from code into a BPMN 2.0 file for stakeholders. Discovery follows connections from the operator-supplied entry point and stops at the connected-component boundary. Cross repository boundaries only when the target appears in `apexyard.projects.yaml`.

Pairs with `/c4` (static system topology) and `/extract-features` (exhaustive feature inventory) as the "what we already have" tooling family. All three are **read-first, ask-only-when-the-code-doesn't-say**.

## Runtime requirements

| Dependency | Used for | Without it |
|------------|----------|------------|
| `bash` ≥ 4 | The skill itself | Required |
| `git` | Anchor resolution + workspace cloning | Required |
| `gh` | Cross-repo registry lookup | Optional: falls back to registry-only |
| `xmllint` | XML validity check | Recommended. The smoke test needs it |
| `python3` ≥ 3.9 | Grid layout (`layout-bpmn.py`, standard library only, `ET.indent` needs 3.9) for `<bpmndi>` coords | Without it: the skill warns and emits a bare BPMN (no `<bpmndi>`). `--skip-layout` needs no Python. |
| `node` + `npx` | `bpmnlint` for the lint gate only | Without Node, the lint step cannot run. Use `--skip-lint` to bypass the gate. |
| `yq` | Registry parsing | Falls back to grep when absent |

Use the disclosure pattern in `docs/getting-started.md` § "Optional: LSP-aware code navigation". Disclose requirements before use and report missing tools when invoked. Never fail silently.

## Path resolution

Use `.claude/hooks/_lib-portfolio-paths.sh` to resolve paths. Read the registry through `portfolio_registry`, per-project docs through `portfolio_projects_dir`, and the workspace directory through `portfolio_workspace_dir`. Source the helper at the start of each bash block that uses these paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
registry=$(portfolio_registry)
workspace_dir=$(portfolio_workspace_dir)
```

Defaults match the single-fork layout. Split-portfolio v2 resolves sibling-repo paths. Do not hardcode `apexyard.projects.yaml` or `projects/` literals. The helper resolves the adopter's mode. See `docs/multi-project.md`.

**Write targets** (see me2resh/apexyard#373 + #443): `projects/<name>/X` paths are canonical adopter-facing forms. In bash, use `"${projects_dir}/<name>/X"`. Never construct paths from `"${PWD}/projects/..."`, `"$(git rev-parse --show-toplevel)/projects/..."`, or literal `./projects/...`. These paths fail in split-portfolio v2 mode, where `projects_dir` resolves to a sibling repo.

**REQUIRED per-block preamble** (see #443): Claude executes each ```bash``` block in a separate shell. The `projects_dir` assignment above does NOT carry into later blocks. Every bash block that writes to `projects/<name>/X` MUST start with this three-line preamble:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
# ... now write to "${projects_dir}/<name>/X"
```

The Path resolution example sources the helper once for documentation. Later blocks must source it again. Treat each ```bash``` fence as a fresh process.

## Usage

```
# Anchored by a process slug + entry point
/process onboarding --from-endpoint POST /signup
/process checkout   --from-machine CheckoutMachine
/process invoicing  --from-job ProcessInvoiceJob
/process billing    --scope src/billing/

# Multiple anchors compose (union, then connected-component)
/process onboarding --from-endpoint POST /signup --from-machine OnboardingMachine

# Project-targeted (when not invoked from inside workspace/<name>/)
/process onboarding --project signup-svc --from-machine OnboardingMachine

# Layout opt-in (default: swimlanes within one pool)
/process onboarding --pools                 # one pool per repo, message flows between

# Re-run a previously generated process: uses anchors recorded in <slug>.process-source.md
/process onboarding                         # regenerates same scope; OFFERS (default-no) to overwrite
/process onboarding --force                 # skip the overwrite prompt
```

If no anchor exists and no `<slug>.process-source.md` exists, stop and ask the operator for an anchor. Do not scan the whole repository. Anchors are mandatory.

## Output location

```
projects/<project>/processes/<slug>.bpmn               ← the BPMN 2.0 artefact (committed)
projects/<project>/processes/<slug>.process-source.md  ← discovery report + interview answers (committed)
projects/<project>/processes/README.md                 ← one-row-per-BPMN index, auto-maintained
```

Sibling structure to `/c4`'s `projects/<name>/architecture/` and `/extract-features`'s `projects/<name>/feature-inventory.md`.

## The seven discovery axes

Scan seven axes, each read-only and bounded by reachability from the anchor. Print findings for operator review **before** writing any file.

### Axis 1: Explicit workflow definitions

State machines and workflow DSLs declare processes explicitly. If one matches the anchor, use it as the highest-signal source.

| Framework | Signature (grep fallback) |
|-----------|---------------------------|
| XState | `\.machine\.(ts\|js)$`, `createMachine\s*\(`, `import .* from ['"](xstate\|@xstate)['"]` |
| Temporal | `@workflow.defn`, `@activity.defn`, `proxyActivities<` |
| Cadence | `@workflow_method`, `@activity_method` |
| AWS Step Functions | `\.asl\.json$`, `"States"\s*:`, `"StartAt"\s*:` |
| Camunda / Cawemo | `\.bpmn$`, `\.cmmn$` (existing files used as starting state, not overwritten blindly) |
| Inngest workflow | `inngest\.createFunction\s*\(` |
| Activiti / Flowable | `\.bpmn(20)?\.xml$` |

### Axis 2: Queue / job orchestration

Job chains describe deferred work: `enqueue(A)` → A runs → A enqueues `B` is a process flow.

| Framework | Signature |
|-----------|-----------|
| BullMQ flows | `new FlowProducer\s*\(`, `\.add\s*\(\s*\{[^}]*children:` |
| BullMQ chains | `new Queue\s*\(`, `new Worker\s*\(`, `\.add\s*\(\s*['"][^'"]+['"]` |
| Celery chains / chords / groups | `chain\s*\(`, `chord\s*\(`, `group\s*\(`, `\.apply_async\s*\(`, `@shared_task` |
| Sidekiq workflows | `class \w+\s*\n\s*include Sidekiq::Worker`, `\.perform_async`, sibling jobs in same module |
| Resque pipelines | `Resque\.enqueue\s*\(`, class `extend Resque::Plugins::*` |
| AWS SQS handlers | Lambda handlers with `Records[].eventSource == "aws:sqs"`, SAM `Events: SQS:` |
| Inngest steps | `step\.run\s*\(`, `step\.sendEvent\s*\(` |

For each job in the connected component capture: name, trigger (queue name / event), and the downstream jobs/events it dispatches.

### Axis 3: Cron + scheduled triggers

Scheduled handlers are process entry points, like HTTP endpoints. Trace what they dispatch.

| Source | Signature |
|--------|-----------|
| `node-cron` | `cron\.schedule\s*\(` |
| `@nestjs/schedule` | `@Cron\s*\(`, `@Interval\s*\(`, `@Timeout\s*\(` |
| APScheduler | `scheduler\.add_job`, `@scheduler\.scheduled_job` |
| Celery beat | `CELERY_BEAT_SCHEDULE`, `beat_schedule\s*=` |
| GitHub Actions cron | `on:` `schedule:` `cron:` in `.github/workflows/*.yml` |
| Vercel cron | `vercel\.json` `"crons"` |
| EventBridge / CloudWatch Events | SAM `Events: Schedule:`, Terraform `aws_cloudwatch_event_rule` with `schedule_expression` |
| Cloudflare Workers cron | `wrangler\.toml` `[triggers]` `crons` |

For each schedule capture: cron expression, handler entry point, and what the handler dispatches downstream.

### Axis 4: State-column transitions

DB columns named `status`, `state`, `phase`, `step`, `stage` carry process state in the schema. Grep the column's literal value set + the service-layer code that writes each transition.

| Source | Signature |
|--------|-----------|
| Prisma | `prisma/schema.prisma` → fields named `status\|state\|phase\|step\|stage` |
| TypeORM / Sequelize | `@Column\s*\(` on fields named `status`/`state`/..., enum types `enum \w+Status` |
| Drizzle | `pgEnum\s*\(`, `mysqlEnum\s*\(`, columns named `status`/`state`/... |
| SQLAlchemy / Django ORM | `Column\s*\(.*Enum`, `models.CharField.*choices=` |
| Active Record (Rails) | `db/schema.rb` columns named `status`/`state`, `enum status:` |
| Raw SQL | `CREATE TABLE` columns named `status`/`state`/`phase` |
| State-writing code | grep `\.status\s*=\s*['"]` then trace back to the function and its callers |

For each state column capture: full enum value set + the call sites that write each value. Each transition is a process edge.

### Axis 5: API choreography

Endpoint A → emit event / enqueue job → endpoint B handles. Trace across route files in the connected component.

| Pattern | Signature |
|---------|-----------|
| Event emission | `eventBus\.emit\s*\(`, `EventEmitter`, `Outbox` writes, `publishEvent\s*\(` |
| Queue dispatch from handler | route handler body containing `\.add\(.*Queue\s*\)`, `enqueue\s*\(`, `.apply_async\s*\(` |
| HTTP fan-out | route handler body containing `fetch\s*\(`, `axios\.(get\|post\|...)`, `httpx\.(get\|post\|...)`, `requests\.(get\|post\|...)`, gRPC client calls |
| WebSocket emit | `io\.emit\s*\(`, `socket\.emit\s*\(`, `ws\.send\s*\(` |

Each event / dispatch / fan-out is a candidate process edge. Check outbound HTTP calls and queue publishes against the registry (axis 6 of the cross-repo flow below).

### Axis 6: Existing BPMN / sequence diagrams

If the project has process diagrams, use them as the starting state. Never overwrite them without review. The operator may have edited them manually.

| Source | Signature |
|--------|-----------|
| BPMN files | `\.bpmn(20)?(\.xml)?$` anywhere in repo |
| CMMN files | `\.cmmn(\.xml)?$` |
| Mermaid sequence diagrams in docs | `docs/processes/*.md` containing ` ```mermaid\nsequenceDiagram` |
| Mermaid flowcharts in docs | `docs/processes/*.md` containing ` ```mermaid\nflowchart` |

When an existing BPMN matches the slug or anchor, load and parse it. During candidate review, show its differences from the axes 1-5 candidate.

### Axis 7: Documented process steps

README sections and `docs/` files with headings like "Onboarding Flow" / "Order Lifecycle" or numbered-step lists are the author's own enumeration.

| Source | Signature |
|--------|-----------|
| README sections | `^##\s+(.*Flow\|.*Process\|.*Lifecycle\|.*Workflow)` headers + the bullet/numbered list that follows |
| `docs/processes/**` | entire directory, if present |
| Numbered-step lists | `^\s*\d+\.\s+` lines within a process section |

Use these sources to confirm or clarify step labels. Do not use them as the primary structure because they are often stale.

## Process

Use `AskUserQuestion` for every operator option menu in this skill.
Follow `.claude/rules/reporting-style.md § Operator choices`.
Keep single yes/no and ticket confirmation prompts as written.
The prose menus below are fallbacks only when the harness lacks `AskUserQuestion`.

### 1. Resolve the anchor + scope

Required inputs (parsed from CLI args):

- **`<process-slug>`**: short kebab-case identifier (`onboarding`, `checkout`, `invoicing`). The BPMN file name, the source-of-truth name, and the registry index key.
- **At least one entry-point anchor** OR an existing `<slug>.process-source.md` to replay from:
  - `--from-endpoint METHOD /path`
  - `--from-machine ClassName`
  - `--from-job JobName`
  - `--scope dir/`
- **Project**: infer from cwd inside `workspace/<name>/`. Use `--project <name>` when supplied. Ask the operator when the project is ambiguous.

If the operator supplies no anchor and no source-of-truth file exists, **stop and ask**:

```
Which process are we mapping?

  process slug: ____________________  (e.g. "onboarding", "checkout")
  one-line description: ____________________
  AND ONE of:
    HTTP endpoint:       e.g. POST /signup
    state machine class: e.g. OnboardingMachine
    queue job name:      e.g. ProcessSignupJob
    directory path:      e.g. src/onboarding/
```

### 2. Discover (axes 1-7, read-only)

Invoke `discover.sh <project-root> --anchor=<json> --max-depth=6` (the discovery engine). It walks the seven axes, applies reachability bounding from the anchor, and outputs a structured candidate model:

```json
{
  "anchor": { "endpoint": "POST /signup", "machine": null, "job": null, "scope": null },
  "axes_with_findings": ["1", "2", "3", "5", "7"],
  "axes_empty": ["4", "6"],
  "nodes": [
    { "id": "evt_start", "type": "event-start", "label": "Signup submitted", "source": "src/routes/signup.ts:14" },
    { "id": "task_validate", "type": "task", "label": "Validate signup payload", "source": "src/routes/signup.ts:18-32" },
    { "id": "task_create_user", "type": "task", "label": "Create user record", "source": "src/services/user.ts:45" },
    { "id": "task_send_verify", "type": "task", "label": "Send verification email", "source": "src/workers/email.ts:12 (queue: send-verify-email)" },
    { "id": "task_verify_identity", "type": "external-call", "label": "Verify identity", "source": "src/services/user.ts:60 → identity-svc#POST /verify-identity", "cross_repo": "identity-svc" },
    { "id": "gw_email_verified", "type": "gateway", "label": "Email verified?", "source": "User.emailVerifiedAt column" },
    { "id": "task_complete_profile", "type": "task", "label": "Complete profile", "source": "src/routes/profile.ts:24" },
    { "id": "evt_end", "type": "event-end", "label": "Onboarding complete", "source": "User.onboardedAt column" }
  ],
  "edges": [
    { "from": "evt_start", "to": "task_validate", "kind": "sequence" },
    { "from": "task_validate", "to": "task_create_user", "kind": "sequence" },
    { "from": "task_create_user", "to": "task_send_verify", "kind": "sequence" },
    { "from": "task_send_verify", "to": "task_verify_identity", "kind": "message", "label": "verify-identity-requested" },
    { "from": "task_verify_identity", "to": "gw_email_verified", "kind": "sequence" },
    { "from": "gw_email_verified", "to": "task_complete_profile", "kind": "sequence", "label": "yes" },
    { "from": "gw_email_verified", "to": "evt_start", "kind": "sequence", "label": "no: resend" },
    { "from": "task_complete_profile", "to": "evt_end", "kind": "sequence" }
  ],
  "external_touchpoints": [
    { "id": "ext_audit_log", "label": "Audit log service", "source": "src/services/audit.ts:8 → POST /audit-log" }
  ],
  "ambiguities": [
    { "node": "task_send_verify", "question": "user-driven, service task, or external API call?" },
    { "node": "task_verify_identity", "question": "identity-svc is registered: follow the trace into it? (default: yes)" }
  ],
  "missing_labels": [
    { "node_id": "task_step2", "current_label": "step2", "evidence": "src/routes/signup.ts:42" }
  ],
  "invisible_lanes_candidates": [
    "Admin approval: if signup matches fraud heuristics, code dispatches `ManualReviewJob` but the approver role isn't in the codebase. Confirm?"
  ]
}
```

### 3. Cross-repo trace (axes 5+ for registered repos)

When any node has `cross_repo: <name>` set, invoke `cross-repo.sh --target=<name>`:

1. Look up the target in `apexyard.projects.yaml` via `portfolio_registry`.
2. If the registry lists the target AND `workspace/<name>/` exists, recurse discovery. Use the receiving endpoint as the new anchor.
3. If registered AND `workspace/<name>/` missing → **OFFER to clone** (default-yes):

   ```
   Cross-repo handoff detected: signup-svc → identity-svc (POST /verify-identity)

   identity-svc is registered in apexyard.projects.yaml but not cloned locally.

   Clone now? (default: yes)
     Yes  → git clone github.com/<org>/identity-svc workspace/identity-svc (gitignored), then continue trace
     No   → render as external touchpoint with documentation
   ```

   If the operator declines, render an external touchpoint. Add `<bpmn:documentation>`: "registered but not cloned. Clone via `git clone github.com/<org>/<repo> workspace/<repo>` to expand on re-run".

4. If the registry does **not** list the target, render an external participant pool (out-of-org). Mark the trust boundary visibly.

Each repo encountered becomes a swimlane (default) or pool (when `--pools` set or interview-selected).

### 4. Present the candidate for operator review

Print the full candidate model in compact form, plus the trace report:

```
PROCESS: onboarding
ANCHOR:  POST /signup (signup-svc)

Discovery (5 / 7 axes had findings):
  ✓ Axis 1: Explicit workflows: OnboardingMachine (XState) at src/onboarding/state.ts
  ✓ Axis 2: Queues: send-verify-email (BullMQ) at src/workers/email.ts
  ✓ Axis 3: Cron: nightly-resend-verify (node-cron) at src/workers/cleanup.ts
  ─ Axis 4: State columns: User.status (pending|verified|complete) at prisma/schema.prisma
  ✓ Axis 5: API choreography: POST /verify-identity → identity-svc
  ─ Axis 6: Existing BPMN: none
  ✓ Axis 7: Documented steps: README "Onboarding Flow" section

Scope: 12 nodes reachable from POST /signup, 3 external touchpoints not expanded
Cross-repo trail:
  signup-svc → POST /verify-identity in identity-svc → emit "identity.verified" →
  onboarding-svc subscribes → completes profile
  (3 repos in scope; identity-svc and onboarding-svc both registered, both cloned)

Candidate model:
  [Start]    "Signup submitted"
    → [Task]    "Validate signup payload"    (src/routes/signup.ts:18-32)
    → [Task]    "Create user record"         (src/services/user.ts:45)
    → [Task]    "Send verification email"    (src/workers/email.ts:12, queue: send-verify-email)
    → [Message] "verify-identity-requested" → identity-svc
    → [Task]    "Verify identity"            (identity-svc / src/routes/identity.ts:8)
    → [Gateway] "Email verified?"            (User.emailVerifiedAt)
        yes → [Task] "Complete profile"      (src/routes/profile.ts:24)
              → [End] "Onboarding complete"  (User.onboardedAt)
        no  → loop to [Start]

External touchpoints (not expanded):
  Audit log service (src/services/audit.ts:8): expand into sub-process? [N/y]

Ambiguities to resolve (will ask in interview):
  - task_send_verify: user-driven, service task, or external API call?
  - task_step2 (src/routes/signup.ts:42): what should this be called in the BPMN?

Invisible lanes (suggested):
  - Admin approval lane: if signup matches fraud heuristics, code dispatches
    ManualReviewJob but the approver role isn't in the codebase. Add lane? [Y/n]

Layout default: swimlanes within one pool (one lane per repo: signup-svc, identity-svc, onboarding-svc)
  Change to pools + message flows? [N/y]   ← shows trust boundaries explicitly

Accept candidate and continue to interview? (a)ccept · (e)dit · (q)uit
>
```

On `e`, enter an edit loop. The operator can add, remove, or relabel nodes, change edge kinds, and redraw swimlane assignments.
On `q`, exit without writing any files. Discard the discovery report. A re-run regenerates it.
On `a`: continue.

### 5. Gap-fill interview

Iterate over `ambiguities`, `missing_labels`, and `invisible_lanes_candidates` from step 2. **Do not ask questions whose answer is already in the discovery report.**

Each interview prompt is a single question:

```
Q1/4: task_send_verify (src/workers/email.ts:12): what kind of task?
  (a) service task: system-driven, no human
  (b) user task    : user has to do something
  (c) send task    : fires off a message/event
  (d) external task: handled by an external system (mark for sub-process expansion)
Choice: a

Q2/4: task_step2 (src/routes/signup.ts:42): what should this step be called in the BPMN?
Label: Persist signup metadata

Q3/4: Add admin-approval lane? (fraud-heuristic dispatch goes to ManualReviewJob; no in-code approver role)
[Y/n]: y
  Lane name (default: "Fraud review"): Compliance review

Q4/4: External touchpoint "Audit log service": sub-process or black-box?
  (a) sub-process: expand inline
  (b) black-box  : single shape, no expansion
Choice: b
```

Append answers to the source-of-truth markdown for replay.

### 6. Generate BPMN 2.0 XML

Invoke `generate-bpmn.sh <project-root> <source-of-truth.md> -o <output.bpmn>`:

1. Build the XML tree from the final node + edge model:
   - `<bpmn:definitions>` root with `targetNamespace="http://apexyard/process/<slug>"`
   - One `<bpmn:collaboration>` containing per-repo pools (when `--pools`) or one pool with per-repo `<bpmn:lane>`s (default).
   - One `<bpmn:process>` per pool (default: one process).
   - `<bpmn:startEvent>` / `<bpmn:endEvent>` for events. `<bpmn:task>` / `<bpmn:serviceTask>` / `<bpmn:userTask>` / `<bpmn:sendTask>` for tasks. `<bpmn:exclusiveGateway>` / `<bpmn:parallelGateway>` for gateways.
   - `<bpmn:sequenceFlow>` for sequence edges. `<bpmn:messageFlow>` for cross-pool / message edges (only valid inside `<bpmn:collaboration>`, not inside `<bpmn:process>`).
   - Every element carries a `<bpmn:documentation>` child citing source evidence (`src/onboarding/state.ts:42-58`, `cron config`, `operator input`).
2. Generate deterministic grid coordinates with Python 3 (standard library only). Columns follow longest paths after removing back edges. Lane bands separate parallel rows. Backward flows use lane-edge corridors. The collaboration plane includes participant and lane shapes. Use `--skip-layout` to emit bare XML.

### 7. Lint and the auto-fix / re-interview / accept loop

Invoke `lint.sh <output.bpmn>`:

1. Run `npx -y bpmnlint <output.bpmn>` with the ruleset:
   - `bpmnlint/recommended` base
   - `label-required` (every flow node has a label)
   - `no-disconnected` (every node is on a path from a start event to an end event)
   - `no-implicit-split` (multiple outgoing sequence flows need an explicit gateway)
   - Overridable via `.bpmnlintrc` in the project root.
2. If violations exist, surface each with file-line context, then offer:

   ```
   bpmnlint reported 2 violations:

   [ERROR] label-required: task_step2 has no label
     element: bpmn:Task id="task_step2" (line 47)

   [WARN]  no-implicit-split: task_create_user has 2 outgoing flows without a gateway
     element: bpmn:Task id="task_create_user" (line 52)

   How to proceed?
     (a) auto-fix where possible: adds placeholder labels, inserts exclusiveGateway for splits
     (r) re-interview affected nodes
     (s) accept with documented exception: adds <bpmn:documentation> stating the override
     (q) quit, leave .bpmn unmodified
   Choice:
   ```

3. On `a`, apply auto-fixes. Slugify `node.id` for labels. Insert gateways with `<bpmn:documentation>` "auto-inserted by /process to satisfy no-implicit-split". Re-run lint.
4. On `r`: jump back to step 5 for only the affected nodes.
5. On `s`: write the exception to `.bpmnlintrc` (per-rule, per-element-id), document the exception in the BPMN's `<bpmn:documentation>`, re-run lint.
6. On `q`, stop. Still write the source-of-truth markdown to preserve progress.

**The skill exits successfully only when `bpmnlint --max-warnings 0` returns 0.** Use `--skip-lint` to bypass (the operator owns the consequences).

### 8. Write outputs

Three files:

1. `projects/<project>/processes/<slug>.bpmn`: the artefact
2. `projects/<project>/processes/<slug>.process-source.md`: the discovery report + interview answers + final candidate model + lint disposition
3. `projects/<project>/processes/README.md`: append/update the index row

If `<slug>.bpmn` already exists:

```
projects/<project>/processes/<slug>.bpmn already exists (last written 2026-04-12).
Overwrite? [N/y]
```

Default to `N`. On `N`, write `<slug>-<YYYY-MM-DD>.bpmn`. Tell the operator the new path. Preserve the original. With `--force`, skip the prompt.

### 9. Report

```
✓ /process onboarding complete

  Artefact:  projects/signup-svc/processes/onboarding.bpmn
  Source:    projects/signup-svc/processes/onboarding.process-source.md
  Index:     projects/signup-svc/processes/README.md

  Scope:     12 nodes, 14 edges, 3 repos, 1 external participant
  Cross-repo: signup-svc → identity-svc → onboarding-svc (all registered, all cloned)
  Lint:      bpmnlint clean (0 errors, 0 warnings)

Preview in Camunda Modeler:
  open https://demo.bpmn.io and drag-drop the .bpmn file
  or: install Camunda Modeler from https://camunda.com/download/modeler/

Re-run /process onboarding when the underlying code changes (it'll OFFER to overwrite).
```

## End-to-end worked example

Goal: map onboarding flow for a SaaS spanning three repos (`signup-svc`, `identity-svc`, `onboarding-svc`).

```bash
$ /process onboarding --from-endpoint POST /signup --project signup-svc

Discovery:
  ✓ Axis 1: OnboardingMachine at src/onboarding/state.ts (XState, 6 states, 8 transitions)
  ✓ Axis 2: send-verify-email queue handler at src/workers/email.ts
  ✓ Axis 5: outbound HTTP POST /verify-identity → identity-svc (registered)

Cross-repo trace:
  signup-svc emits "identity.verified" on success
  onboarding-svc subscribes (per its src/subscriptions/identity.ts:14)
  onboarding-svc dispatches CompleteProfileJob

Candidate model: 12 nodes, 14 edges, 3 swimlanes (one per repo within one pool)

Ambiguities:
  - task_send_verify: service / user / send / external?
  - task_step2 in src/routes/signup.ts:42: what label?

Operator review: accept

Interview:
  Q1: task_send_verify → send task
  Q2: task_step2 → "Persist signup metadata"
  Q3: external touchpoint "Audit log service" → black-box

Generate BPMN: 1.2 KB raw XML + grid coordinates → 4.8 KB total
Lint: bpmnlint clean (0 errors)

✓ projects/signup-svc/processes/onboarding.bpmn written
```

Opens cleanly in Camunda Modeler with all three swimlanes, message flows between, and source citations under each element.

## Anti-patterns

- **Exhaustive scans without an anchor**: the skill refuses. Process diagrams need bounded scope.
- **Auto-merging cross-repo without operator review**: the candidate-model review step exists precisely to confirm the trace is correct before BPMN emission.
- **DMN or CMMN output**: out of scope. These formats need different skills if requested.
- **Camunda-specific extensions** (`<camunda:formKey>`, `<zeebe:taskDefinition>`): out of scope. Vanilla BPMN 2.0 only. Adopters who want engine-specific extensions post-process with their engine's tooling.
- **Live syncing or BPMN execution**: out of scope. One-shot scan-then-generate.
- **Round-trip import** (read hand-edited `.bpmn` back into the interview state): out of scope. Re-run and OFFER-to-overwrite is the supported flow.
- **Asking questions whose answer is in the discovery report**: the interview should target gaps only.

## Why this skill exists

A process diagram written from memory drifts the moment a developer changes a state-machine transition or adds a new queue handler. A process diagram extracted from code stays accurate but skips the invisible lanes (human approvers, external systems not called from this repo). This skill closes both gaps: code is the source, interview is the augmentation, the operator owns the disposition of ambiguities.

For microservices, the registry-based cross-repo trace includes the whole connected component in the BPMN. This avoids repository searches during stakeholder meetings. Pools and message flows show trust boundaries when the operator selects them.

## Out of scope (v1)

- DMN and CMMN output
- Camunda 7 / 8 extension attributes
- BPMN execution / engine integration
- Round-trip from hand-edited `.bpmn` back into the interview state
- Heuristic URL matching for cross-repo handoffs (registry-only)
- Live syncing across runs
- DSL output for Cadence / Temporal / Step Functions
- Multi-process canvases (one process per invocation)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

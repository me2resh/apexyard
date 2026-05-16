---
id: AgDR-0025
timestamp: 2026-05-16T00:00:00Z
agent: claude-opus-4-7
model: claude-opus-4-7
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#256
---

# `/process` skill — BPMN 2.0 target, discovery-first authoring, cross-repo via registry

> In the context of shipping `/process` per #256 (a "what is the business process this code actually implements" skill that walks one or more repos, augments via interview, and emits a diagram for stakeholder review), facing the choice between several output formats (BPMN 2.0 / DMN / CMMN / Mermaid sequence / hand-rolled flowchart), several layout strategies (auto-layout npm package / manual coords / no `<bpmndi>` at all), several lint gates (`bpmnlint` / vanilla XML validation / none), several authoring modes (operator-only interview / read-first-then-ask / pure-static), several swimlane conventions (one pool with swimlanes / pools with message flows), several cross-repo signals (registry lookup / heuristic URL pattern matching), and several missing-clone strategies (on-demand cloning offer / always black-box / always auto-clone), I decided to ship **BPMN 2.0 XML as the output format, `bpmn-auto-layout` for `<bpmndi>` coords, `bpmnlint` as a hard gate, read-first-then-ask (the seven-axis discovery from the ticket), one pool with per-repo swimlanes by default with pools+message-flows as an interview opt-in, registry-lookup as the only cross-repo signal, and an on-demand cloning offer when the registry entry exists but `workspace/<name>/` doesn't** — accepting that vanilla BPMN 2.0 means no engine-specific extensions (no Camunda 7/8 attributes), `bpmn-auto-layout` requires Node + npm at run time, `bpmnlint` may flag synthesized models that operators would accept (so the loop offers auto-fix / re-interview / accept-with-exception), heuristic URL matching for cross-repo handoffs is out of scope (false-positive risk too high without the registry as ground truth), and on-demand cloning prompts the operator instead of silently doing it (cost of disk + LSP-plugin setup is owned, not assumed).

## Context

Issue #256 asks for a sibling to `/extract-features` (exhaustive feature inventory) and `/c4` (system topology) that produces a process diagram by reading code first and interviewing the operator only on the gaps. The defining tension is that operators write process diagrams from memory; the code already encodes the truth; the skill should make the code the source and the interview the augmentation, not the other way around.

Three structural questions need answering before any code lands:

1. **What's the output format?** Diagrams meant for stakeholders need to open in a tool stakeholders already use. BPMN 2.0 is the lingua franca for business process diagrams — Camunda Modeler, bpmn.io, Cawemo, Signavio all open `.bpmn` files. Mermaid `sequenceDiagram` and `flowchart` would be cheaper to emit (no XML, no schema, no layout engine) but they don't carry process semantics (pools, lanes, gateways, message flows) and they don't open in BPM tools. DMN and CMMN are sibling OMG standards for decision tables and case management — different problem space; out of scope.

2. **How does BPMN get coordinates?** A BPMN file without a `<bpmndi:BPMNDiagram>` block opens in Camunda Modeler as "blank" — every box piles at origin (0,0) until the operator manually arranges them. That's a non-starter for an "open it, share it" workflow. Three paths: (a) emit no `<bpmndi>`, tell the operator to auto-layout in Camunda Modeler; (b) hand-roll a layout algorithm in bash; (c) wrap the `bpmn-auto-layout` npm package which is the de-facto standard for programmatic BPMN layout.

3. **What's the cross-repo signal?** The skill must follow process flows across microservice boundaries. Two candidate signals: registry-lookup (`apexyard.projects.yaml` lists every repo under management; a HTTP/queue handoff whose target name matches a registry entry crosses repos) vs heuristic URL matching (parse hostnames + service-discovery names, try to map them to GitHub repos in the org). Heuristic matching has a high false-positive rate (`https://api.example.com` could be anything); registry-lookup has perfect precision at the cost of being explicit — only registered repos participate in the trace.

Adjacent precedent in the framework:

- `/extract-features` — exhaustive scan, no anchor; produces a flat catalogue, not a graph. Different shape because the goal is "every feature", not "this connected component".
- `/c4` — anchor-scoped (one project), produces Mermaid that GitHub renders inline. The Mermaid-renders-inline trick works because C4 diagrams have low semantic density (8 box types max); BPMN has > 100 element types, no GitHub renderer, and target stakeholders are PMs / domain experts, not engineers reading rendered markdown.
- `/threat-model` — produces a DFD as Mermaid; sister DFD-as-Threat-Dragon-JSON is being built in #255. Both serialize a diagram-shaped model to an external tool's format. Same pattern; different tool.
- `/handover` — cloning offer is **default-no**, surfaces disk cost + LSP-plugin caveats. Precedent for "ask before doing the thing that costs the operator something".

## Options Considered

### 1. Output format

| Option | Pros | Cons |
|--------|------|------|
| **BPMN 2.0 XML** | OMG standard since 2011; opens in Camunda Modeler, bpmn.io, Cawemo, Signavio, Bizagi; carries all the process semantics (pools, lanes, gateways, message flows, intermediate events, sub-processes); domain experts already speak this dialect | XML is verbose; coordinates needed for visual rendering (`<bpmndi>`); strict schema means lint matters |
| **Mermaid `sequenceDiagram`** | GitHub renders inline; tiny output; zero deps | No pools/lanes (only participants); no gateways; no message-flow vs sequence-flow distinction; stakeholders outside engineering don't read Mermaid |
| **Mermaid `flowchart` with subgraphs** | GitHub renders inline; subgraphs approximate swimlanes | Process semantics (gateway types, message vs sequence flow) get squashed to generic boxes; not a BPMN substitute |
| **DMN 1.4** | OMG standard for decision tables | Wrong shape — DMN is for "what's the decision policy" (deny / approve table); not for "what's the process flow" |
| **CMMN 1.1** | OMG standard for case management | Wrong shape — CMMN is for unstructured ad-hoc work (insurance claims, support cases); not the same as deterministic process flows |
| **Hand-rolled JSON / YAML graph** | Total flexibility, easy to emit | Opens in nothing; stakeholder review is "trust the bash script"; defeats the "share it" requirement |

Decision-relevant dimensions:

- **Opens in stakeholder tooling without a build step**: BPMN ✅ (Camunda Modeler downloadable, bpmn.io free-tier web app, both render `.bpmn` files); Mermaid sequence ❌ (only engineering tooling renders it); flowchart ~ (GitHub yes, but PMs don't use GitHub renderers for stakeholder review).
- **Carries the process semantics the ticket requires** (pools, lanes, gateways, message flows, swimlanes for cross-repo): BPMN ✅; everything else ❌ at minimum on swimlanes + message flows.
- **Tool ecosystem for the lint step**: BPMN has `bpmnlint` (active, npm); the other formats have no equivalent.

BPMN 2.0 wins on all three.

### 2. Layout strategy

| Option | Pros | Cons |
|--------|------|------|
| **`bpmn-auto-layout` npm package** | De-facto standard for programmatic BPMN layout; same project family as bpmn.io (the rendering engine inside Camunda Modeler); maintained; well-understood failure modes (cycles, dense graphs) | Requires Node + npm at run time; ships ~5MB of dependencies via npx |
| **No `<bpmndi>` block** | Trivial to emit | File opens "blank" in Camunda Modeler — every shape stacked at origin until manually arranged. Defeats the share-and-review workflow entirely. |
| **Hand-rolled layout in bash** | Zero runtime deps beyond what's already shipped | Layout is hard. The BPMN spec doesn't constrain it; readable layouts require graph-aware row/column assignment + edge routing; reimplementing what `bpmn-auto-layout` already does well is a multi-week ticket with worse results |
| **Defer layout to Camunda Modeler's "Distribute layout" menu item** | No code change | Manual step on every regenerate; documented poorly; some forks of Modeler removed the menu item; this would force every operator to learn Modeler's idiosyncrasies — wrong direction |

`bpmn-auto-layout` wins. The Node + npm dependency is the same kind of cost as `bpmnlint` (which is also npm-only); disclosing both in the README mirrors the LSP-plugin disclosure pattern from #208.

### 3. Lint gate

| Option | Pros | Cons |
|--------|------|------|
| **`bpmnlint` with the `recommended` ruleset + opt-ins** | Catches the common malformedness (disconnected nodes, missing labels, implicit splits, multiple-start-events); produces actionable file:line errors; configurable via `.bpmnlintrc` | npm dep; some rules may be too strict for synthesized models (e.g. a node we couldn't determine the label for) — needs the auto-fix / re-interview / accept-with-exception loop |
| **xmllint schema validation only** | No npm dep; catches XML-shape errors | Doesn't catch BPMN-semantic errors (disconnected sub-graph, no start event, missing labels); a schema-valid file can still render badly |
| **No lint** | Simplest | Operators commit broken BPMN that Camunda Modeler refuses to open; failure happens to the stakeholder, not the generator |

`bpmnlint` wins. The synthesized-model-too-strict concern is real but addressable inside the loop (the operator chooses auto-fix / re-interview / accept) rather than by skipping the gate.

### 4. Authoring mode

| Option | Pros | Cons |
|--------|------|------|
| **Read first, ask only on gaps (per ticket)** | Discovery report shows the operator what the code already says before any question; interview targets only the ambiguities + invisible-to-code lanes; final BPMN reflects what's in production | Requires the seven-axis discovery engine; needs an explicit candidate-model review step before generation |
| **Operator-only interview** | Simple — ask 12 questions, draw boxes from the answers | Answers reflect the operator's memory, not the code; the diagram drifts from production the moment a developer changes a state-machine transition; defeats the value of the skill |
| **Static-only, no interview** | No human-in-the-loop overhead | Operators can't add the invisible lanes (approvers, external systems not called from this repo), can't disambiguate `step1` → "Verify identity", can't decide swimlane vs pool layout |

Read-first-then-ask wins on the ticket-explicit requirement. The interview is a gap-filler, not the primary authoring mode.

### 5. Swimlane convention (multi-repo BPMN layout)

| Option | Pros | Cons |
|--------|------|------|
| **One pool, swimlanes per repo (default)** | Reader sees the whole flow in one boundary; sequence flows are valid between lanes; visually compact | Per-repo trust boundaries are implicit (a sequence flow looks the same whether it crosses a process boundary or not) |
| **Pools per repo, message flows between them (opt-in)** | Trust boundaries are explicit (only message flows cross pool boundaries); semantically more accurate for microservices | Visually denser; each pool is its own process boundary, which can confuse operators expecting a single end-to-end view |
| **No convention; always swimlanes** | Simplest | Forces the swimlane shape on operators who want the trust-boundary view |
| **No convention; always pools** | Most accurate | Worst readability default for the common 1-2-repo case |

Default to swimlanes (readability), offer pools+message-flows during the interview when cross-repo handoffs are detected and the operator wants the trust-boundary view. The choice is captured in the per-process source file so re-runs preserve it.

### 6. Cross-repo signal

| Option | Pros | Cons |
|--------|------|------|
| **Registry-lookup (`apexyard.projects.yaml`)** | Perfect precision — only registered repos participate; matches the framework's "explicit list, no auto-discovery" convention | Requires the operator to register the target repo first; cross-repo handoffs to unregistered repos render as external touchpoints |
| **Heuristic URL pattern matching** | Catches more handoffs without registry maintenance | High false-positive rate (`api.example.com` could be anything); high false-negative rate (env-driven hostnames don't grep); produces unreliable diagrams that the operator can't easily correct |
| **Hybrid: registry-first, heuristic fallback** | Best of both | Hybrid with two precision levels in the same diagram is harder to reason about than "either it's in the registry or it's external" |

Registry-lookup wins on the framework's "explicit-over-implicit" principle. Same convention as `/projects`, `/inbox`, `/tasks`. Unregistered targets render as external participant pools (clearly marked out-of-org), which is the right shape for actual third parties (Stripe, SendGrid) and a useful prompt for "should this be registered?" when it's actually a sibling internal service.

### 7. Missing-clone strategy

| Option | Pros | Cons |
|--------|------|------|
| **On-demand cloning offer (default-yes)** | The trace continues when the operator wants depth; the operator sees the disk cost before accepting | One more prompt per missing clone |
| **Always auto-clone** | No prompts | Silent disk consumption; bad fit for operators on metered/small disks; same anti-pattern `/handover` explicitly avoids |
| **Always black-box (never offer)** | Predictable; no surprises | Cross-repo traces stop at the first un-cloned target, even when continuing would be trivial; under-uses the registry signal |

Default-yes cloning offer mirrors `/handover`'s clone offer (#188). The operator can always decline; the BPMN then renders the unexpanded target as an external touchpoint with a `<bpmn:documentation>` explaining "registered but not cloned — expand by running `git clone github.com/<org>/<repo> workspace/<repo>`".

## Decision

Chosen: **the seven decisions above**, taken together as the v1 shape of the skill. Concretely:

- **Output**: BPMN 2.0 XML at `projects/<project>/processes/<slug>.bpmn` (resolved via `portfolio_projects_dir`). Sibling source-of-truth `<slug>.process-source.md` carries the discovery report + interview answers for replay.
- **Layout**: `<bpmndi:BPMNDiagram>` populated via `bpmn-auto-layout` (`npx -y bpmn-auto-layout`). README discloses Node + npm runtime dep.
- **Lint**: `bpmnlint` with the `recommended` ruleset + `label-required`, `no-disconnected`, `no-implicit-split`; `--max-warnings 0` is the gate. `.bpmnlintrc` in the project root overrides per-project. Violations enter a loop: auto-fix → re-interview → accept-with-documented-exception.
- **Authoring**: seven-axis discovery (per the ticket — state machines, queues, cron, state columns, API choreography, existing BPMN/Mermaid, documented steps) → candidate-model review → gap-fill interview → BPMN emission. Discovery is **read-only**; nothing is written until the operator accepts the candidate.
- **Anchor required**: process slug + one-line description OR explicit entry point (`--from-endpoint`, `--from-machine`, `--from-job`, `--scope`). Re-running `/process onboarding` later regenerates the same scope.
- **Cross-repo**: registry-lookup only. Targets in `apexyard.projects.yaml` cross repos into the same connected component (default: swimlane per repo within one pool; opt-in pools+message-flows). Targets not in the registry render as external participant pools.
- **Missing clone**: default-yes offer to clone on-demand; decline → render as external touchpoint with explanatory `<bpmn:documentation>`.
- **Provenance**: every BPMN element carries a `<bpmn:documentation>` child citing its source evidence (`src/onboarding/state.ts:42-58`, `cron config`, `operator input`).
- **Index**: `projects/<project>/processes/README.md` maintained as a one-row-per-BPMN index with anchor, last-generated date, one-line description.

## Consequences

### Immediate

- Operators with Node + npm get a one-command lint-clean BPMN file that opens cleanly in Camunda Modeler. Operators on a Node-less environment see a clear error during the lint step ("install Node + npm or use `--skip-lint`"); the BPMN itself still emits (XML is bash-emit-able), so the skip path is usable for review-only flows.
- The skill adds two npm dependencies to the framework's runtime surface: `bpmn-auto-layout` and `bpmnlint`. Both are pulled via `npx -y` (no `package.json` shipped at the framework level), so single-fork adopters with no Node setup see them only at the moment they invoke the skill.
- Cross-repo traces are bounded by the registry — adopters with two unregistered microservices that participate in the same flow see the trace stop at the boundary with a hint to register the sibling.
- Re-runs regenerate the same scope (anchor + reachability) deterministically. The source-of-truth markdown preserves the discovery report + interview answers, so the second run can be diffed against the first.

### Deferred

- **Round-trip from hand-edited `.bpmn` back into the candidate-model interview state** is out of scope (per ticket). Re-running the skill emits a fresh BPMN; operators who hand-edited the previous one will see it overwritten unless they decline the OFFER-to-overwrite (default-no, same UX as `/extract-features`).
- **Live syncing** is out of scope. One-shot scan-then-generate, not a continuous-update tool.
- **Camunda 7 / 8 extension attributes** (e.g. `<camunda:formKey>`, `<zeebe:taskDefinition>`) are out of scope. Vanilla BPMN 2.0 only. Adopters who want engine-specific extensions can post-process the file with their engine's tooling.
- **DSL output for Cadence / Temporal / Step Functions** is out of scope. BPMN is the only target in v1.
- **Heuristic URL matching for cross-repo handoffs** is out of scope. Registry-only.
- **DMN / CMMN support** is out of scope. Different formats, different skills if demanded.

### Costs if we're wrong

Moderate. The format choice (BPMN 2.0) is sticky — if BPMN tooling stagnates or stakeholders prefer a different format, the source-of-truth markdown lets us regenerate to a new target without re-running discovery (the discovery report is format-agnostic). The npm-dependency choice is reversible — `bpmn-auto-layout` and `bpmnlint` could be swapped for hand-rolled alternatives (or dropped entirely with manual-Modeler-layout instructions) without changing the user-facing flow.

The registry-only cross-repo decision is the highest-risk one — if adopters consistently want to trace into unregistered repos, the heuristic-fallback option becomes relevant. The mitigation today is clear: register the target. If we see consistent friction here, we can add a `--include-repo` flag that takes ad-hoc owner/repo pairs without requiring registry edits.

### Costs if we're right but wait

Significant. Process diagrams are the artefact stakeholders use to review business logic; without them, every cross-team conversation about "how does onboarding actually work" requires a code-walking session. The skill replaces a multi-hour synchronous activity with a one-shot generation + targeted-question pass. Each month without it is a month of avoidable architecture-meeting drag.

## Artifacts

- Skill: `.claude/skills/process/SKILL.md` + `discover.sh` + `cross-repo.sh` + `generate-bpmn.sh` + `lint.sh`
- Tests: `.claude/skills/process/tests/smoke.sh` (single-repo discovery), `tests/test_cross_repo.sh` (two-repo handoff trace), `tests/test_bpmn_emit.sh` (XML validity + `<bpmndi>` presence + lint exit code)
- Ticket: [me2resh/apexyard#256](https://github.com/me2resh/apexyard/issues/256)
- PR: (filled at merge time)

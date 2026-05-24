# AgDR-0050 — Agent runtime overhaul

> In the context of ApexYard's 19-role persona taxonomy (in `roles/<dept>/`) running today as **in-thread role-adoption** — no model isolation, no tool restriction, no separated context — plus 5 utility agents (Rex, Hatim, Munir, Tariq, Idris) running as ad-hoc sub-agents with no centralised routing surface, facing the operator-stated need to (a) assign models per role (Opus / Sonnet / Haiku / local Ollama) for cost + quality optimisation, (b) restrict tools per role (Backend Engineer needs Edit/Write; QA Engineer doesn't), (c) isolate context (a role's specialised prompt shouldn't pollute the main thread until invoked), and (d) edit the agent → model mapping in ONE central file kept in the private portfolio repo — I decided to promote all 19 roles to first-class Claude Code sub-agents (24 total with utility agents folded in), ship them with framework default models from a 24-entry decision matrix, and layer an adopter-facing `agent-routing.yaml` customisation file that propagates per-agent model + endpoint overrides into `.claude/agents/*.md` frontmatter at SessionStart, to achieve per-agent cost / quality / privacy optimisation at adopter scale while keeping the public fork shipped with framework defaults that work out-of-box, accepting the maintenance cost of 24 agent files + a new YAML config surface + a SessionStart sync hook + drift-prevention guards + an external local-routing feasibility spike (#348) whose verdict gates which agents qualify for local-routing entries in the customisation surface.
>
> **Status**: ACCEPTED — cross-cutting design. Each axis below is a load-bearing decision. Implementation lives in tickets #347 (promotion + matrix), #351 (routing config + sync hook), #348 (local-routing spike). This AgDR is referenced by the first PR of each.

**Metadata** — Status: ACCEPTED · Category: architecture · Supersedes: none · Related: [AgDR-0011](AgDR-0011-bootstrap-skill-exemption.md), [AgDR-0018](AgDR-0018-persona-naming-convention.md), [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md), [AgDR-0041](AgDR-0041-sessionstart-v2-anchor-sweep.md), [AgDR-0043](AgDR-0043-geo-audit-skill.md). (Body-H1 only, no YAML frontmatter — per the live convention since markdownlint MD025 trips on YAML title + body H1 simultaneously.)

## Context

ApexYard's runtime model for personas has been **in-thread role-adoption** since v1: 19 markdown files in `roles/{engineering,product,design,security,data}/` define identities, responsibilities, CAN/CANNOT lists, and handoff artefacts. When a trigger fires (per [`role-triggers.md`](../../.claude/rules/role-triggers.md)) — auto-detection on PR-diff paths, tracker labels, or operator prompts like "act as the QA Engineer" — the main thread reads the role file and adopts the persona FOR THE DURATION of the work.

This shape has three structural limits:

1. **No per-role model assignment**. The main thread runs on whatever model is driving the conversation — typically the operator's primary tier (Opus or Sonnet). A QA Engineer doing AC-verification checklists pays Opus prices for Haiku-grade work. A Tech Lead doing architectural design gets the same model as a build-engineer doing routine edits. No knob to differentiate.

2. **No per-role tool restriction**. A role file's CAN / CANNOT list is **prose** — the model is asked to respect it. There's no mechanical enforcement that, say, a QA Engineer doesn't `Edit` source code (QA verifies, doesn't ship). Tool restrictions live only as expectations, not as runtime gates.

3. **No context isolation**. Adopting a role means injecting the role file's ~120 lines into the main thread. Multiple role-switches in one session compound — the main thread carries the union of all adopted-role contexts. Context-window pressure on long sessions is real.

Meanwhile, the framework ships 5 utility sub-agents (Rex, Hatim, Munir, Tariq, Idris) that DO have isolated context + tool restrictions, but their model assignment is `inherit` (no explicit `model:` frontmatter) — they too pay the parent thread's model rate.

The operator articulated the need explicitly: per-role model assignment for cost + quality + privacy optimisation, AND a **one-file customisation surface** in the private portfolio repo so the public fork ships framework defaults that work-out-of-box without leaking adopter-specific routing choices to the public tracker.

This AgDR addresses all six axes of that overhaul in one place. Splitting the design across three ticket bodies (#347 / #348 / #351) was the initial drafting shape, but the cross-cutting decisions — file shape, routing schema, drift prevention, role-trigger integration — kept slipping between tickets. One AgDR locks the shape; three tickets ship the work in 10-12 PRs against a shared design.

## Options Considered

The six load-bearing decisions are presented as one option-matrix each. Cross-axis trade-offs are flagged in the "Decision" section below.

### Axis 1 — File shape (where persona definitions live)

| Option | Pros | Cons |
|--------|------|------|
| **A. Wrap** — `roles/<dept>/<role>.md` keeps the persona definition; `.claude/agents/<role>.md` is a thin wrapper with `model:` + `allowed-tools:` + a one-line `## Role` section that references `@roles/<dept>/<role>.md` | No content duplication; `roles/` stays as canonical persona definition + AgDR cross-reference target; smallest delta to existing structure | Two-file lookup at agent-invocation time (negligible cost); operators must understand the wrap relationship |
| **B. Merge** — content moves into the agent file; `roles/` deprecated-aliased or retired | Single source of truth at the runtime point; simpler mental model for new adopters | Loses the `roles/` directory as an organisational artefact (org-chart shape); breaks every AgDR + workflow cross-reference to `roles/` paths; one-time migration is a churn-pull |
| **C. Mirror** — full content in BOTH `roles/` and `.claude/agents/` | Either lookup path works | Permanent duplication = drift surface; sync-check via smoke test is additional infra; persona-definition edits land in two places |

### Axis 2 — Default model matrix (the 24 entries the public fork ships)

The matrix is presented as one option (`opus` 5 / `sonnet` 17 / `haiku` 2), with the alternative being either "all-Sonnet" (no differentiation) or "all-Opus" (no cost optimisation).

| Persona / Agent | Model | Why |
|-----------------|-------|-----|
| Tech Lead (Hisham) | opus | Architectural depth + cross-stack design |
| Head of Engineering (Khalid) | opus | Cross-project engineering strategy |
| SRE (Saif) | opus | Incident-response diagnosis depth |
| Pen Tester (Hamza) | opus | Adversarial exploration / exploit reasoning |
| Security Auditor (Hakim) | opus | OWASP / threat-model depth (existing utility agent Hatim aligns here) |
| Code Reviewer (Rex) | opus | PR diff review + handbook reasoning (existing utility) |
| Backend Engineer (Karim) | sonnet | Implementation default |
| Frontend Engineer (Yasmin) | sonnet | Implementation default |
| Platform Engineer (Adel) | sonnet | CI / infra-as-code |
| Data Engineer (Anwar) | sonnet | Pipeline / ETL implementation |
| Head of Product (Omar) | sonnet | Roadmap / strategy |
| Product Manager (Mariam) | sonnet | PRD authoring |
| Product Analyst (Hanan) | sonnet | Market / metric analysis |
| Head of Design (Maha) | sonnet | Design-system decisions |
| UI Designer (Nour) | sonnet | Visual spec |
| UX Designer (Iman) | sonnet | User flow / IA |
| Head of Security (Faisal) | sonnet | Strategic, less depth-bound than auditor |
| Head of Data (Khalil) | sonnet | Strategy |
| Dependency Auditor (Munir, utility) | sonnet | Pattern-matching across package files |
| PR Manager (Tariq, utility) | sonnet | Tool-call-heavy + narrative-quality PR bodies |
| Ticket Manager (Idris, utility) | sonnet | Schema-conforming output + interactive interview |
| QA Engineer (Salim) | haiku | AC checklist verification — cheap, repeatable |
| Data Analyst (Nadia) | haiku | SQL / dashboard runs — quantitative, fast |

Adopters override via the routing config (Axis 3). The matrix is the **default**, not the floor or the ceiling.

### Axis 3 — Routing config schema + location

| Option | Pros | Cons |
|--------|------|------|
| **A. YAML config in private repo** (`<private_repo>/agent-routing.yaml`, single-fork: gitignored `<fork>/agent-routing.yaml`) | One file edit, source-controlled in private repo; reviewable diffs; survives across machines | New file class; sync mechanism needed |
| **B. JSON config block in `.claude/project-config.json`** | Reuses existing config infrastructure | Mixes adopter routing config with framework defaults; YAML is more readable for nested per-agent entries |
| **C. Per-user `~/.claude/agents/<name>.md` overrides** (Claude Code's existing user-level pattern) | No framework changes needed | Per-user, not per-fork — adopter has to set up overrides on every machine; loses the "private repo as source of truth" property |
| **D. Env vars per agent** (`APEXYARD_AGENT_<name>_MODEL=opus`) | Trivial to implement | Doesn't scale beyond model choice — endpoints, env vars, timeouts need more structure |

### Axis 4 — Sync mechanism (how routing overrides get applied)

| Option | Pros | Cons |
|--------|------|------|
| **A. SessionStart hook rewrites `.claude/agents/*.md` frontmatter** | Transparent to adopter (re-session = re-apply); Claude Code reads the rewritten file natively; idempotent | Modifies working-tree files at session start (must be gitignored or clean-filtered); pre-commit guard required |
| **B. CLI tool the adopter runs after editing the routing config** (`bin/apply-agent-routing.sh`) | Explicit + reviewable | Adopters forget to run; bad UX |
| **C. Generated agent files via clean-filter** (`.gitattributes` strips `model:` at git-add time) | Working tree dirty / commit clean | Complex; rare-knowledge git feature; debugging is painful |
| **D. Shadow agent files at `.claude/agents-effective/`** | No mutation of canonical files | Claude Code's agent-discovery glob is `.claude/agents/*` — can't easily redirect without upstream changes |

### Axis 5 — Local-routing integration (how Ollama / LiteLLM endpoints work)

| Option | Pros | Cons |
|--------|------|------|
| **A. `endpoint:` field in routing entries → SessionStart hook sets `ANTHROPIC_BASE_URL`** | Routes via LiteLLM proxy; Claude Code's existing endpoint-override path; matches Bedrock / Vertex routing precedent | Session-scoped env var — all agents on the same session share the endpoint, so mixed remote + local in one session is harder; spike (#348) verifies viability |
| **B. Per-agent env-var injection at agent invocation** | Mix-and-match per-agent | Claude Code may not expose per-agent invocation env scoping — needs upstream change or wrapper |
| **C. Wait for Claude Code to ship native local-model routing** | No framework change | Indefinite timeline; punts the operator's question |
| **D. Skip local routing entirely — remote only** | Simplest | Loses the privacy / cost / offline lever entirely |

### Axis 6 — Role-trigger integration (auto-activation routes through sub-agent)

| Option | Pros | Cons |
|--------|------|------|
| **A. Auto-trigger spawns the matching sub-agent (replaces in-thread persona injection)** | Full isolated-context + tool-restricted behaviour; persona-marker convention preserved at the operator surface | Loses shared context with the main thread — sub-agent doesn't know "what just happened" without explicit hand-off in the prompt |
| **B. Trigger keeps in-thread injection; operator manually spawns sub-agent when needed** | Backwards-compatible with current behaviour | Loses the cost / model-isolation benefit on triggered activations |
| **C. Hybrid — trigger spawns sub-agent for some roles (QA / Pen Tester / Data Analyst), keeps in-thread for in-flow roles (Backend / Frontend Engineer)** | Best of both — sub-agent for parallel-isolated work, in-thread for ship-the-code flow | Per-role configuration of trigger behaviour; one more knob |

## Decision

Chosen per axis:

1. **Axis 1 — Wrap (A)**. `roles/<dept>/<role>.md` keeps the persona definition; `.claude/agents/<role>.md` is a thin wrapper with `name`, `description`, `model`, `allowed-tools`, `persona_name` frontmatter, plus a `## Role` section that references `@roles/<dept>/<role>.md`. Two-file lookup is acceptable; the `roles/` directory is too central to AgDRs + workflow cross-references to retire.

2. **Axis 2 — The 24-entry default matrix above**. Opus for depth + reasoning, Sonnet for the majority + tool-use-heavy, Haiku for checklist-shaped repeatable work. Adopters override per agent via Axis 3 routing config. Matrix is reviewable + reversible.

3. **Axis 3 — Wrap A: YAML config in private repo**. `<private_repo>/agent-routing.yaml` in split-portfolio mode; `<fork>/agent-routing.yaml` gitignored in single-fork mode. Schema documented in #351's ticket body + `docs/multi-project.md`. Single source of truth for adopter customisation. `_lib-portfolio-paths.sh` gains a `portfolio_agent_routing` resolver.

4. **Axis 4 — SessionStart hook (A) with pre-commit + pre-push guards**. Hook `apply-agent-routing.sh` runs at SessionStart, reads the routing YAML, rewrites the affected agent-file frontmatter in-place. Public-fork hygiene preserved via two mechanical guards: `pre-commit` blocks commits where a `model:` line differs from the framework default (with `# routing-config:override <reason>` escape hatch for intentional one-offs); `pre-push` sweeps the same surface before ANY push (not just to public-class remotes). Drift is mechanically caught, not relied-on-via-discipline.

> **Note on push-gate scope (resolved #359).** Earlier drafts of this AgDR said the pre-push guard "sweeps before any push to a public-class remote." The shipped `block-agent-routing-drift.sh` fires on every push regardless of remote class — and that's the right design. Even a push-to-private-tracking-branch can be a leak vector if the operator later changes the remote, and adopters who are staging a deliberate framework-default change still need to label it with the `# routing-config:override` escape hatch before pushing anywhere. The broader-scope behaviour is the actual design intent; AgDR-0050 prose now matches the implementation.

5. **Axis 5 — `endpoint:` field + `ANTHROPIC_BASE_URL` (A)**. The routing schema supports `endpoint:` as a first-class field. Mixed remote-and-local on one session is **deferred** to v2 — v1 ships with the understanding that either ALL agents on a session route through the local proxy OR none do, until Claude Code surfaces per-agent invocation env scoping.

> **Note on local-model recommendations (resolved #351 PR 4 + #348).** Earlier drafts of this AgDR (and the #348 spike) framed local-routing as "validate specific models, then ship recommended entries in `agent-routing.yaml.example`." The design shifted in #351 PR 4: **Claude is the framework default, local-model routing is adopter-opt-in via a commented Example C entry, and the framework does NOT ship a recommended local model.** Rationale: hardware varies too much across adopter machines (Apple Silicon vs Linux GPU vs CPU-only, RAM tier, model-size sweet spot) for any "framework-recommended" entry to be safe — it'd mislead more adopters than it'd help. The schema ships the pattern; adopters pick a candidate that fits their machine + validate against their own workload. #348 closed as out-of-scope under the new design; the prep doc stays at `projects/apexyard/spike-348-prep.md` for any adopter who wants to run the validation against their own hardware. No `--local` flag ships in v1 — the `endpoint:` field is set per-agent in `agent-routing.yaml` directly.

6. **Axis 6 — Hybrid (C)**. Triggered activations spawn sub-agents for **isolated-work-class** roles (QA Engineer, Pen Tester, Data Analyst, all 5 Heads of, Security Auditor, Tech Lead for architectural reviews), and keep in-thread injection for **in-flow-class** roles (Backend Engineer, Frontend Engineer, Platform Engineer, Data Engineer, Product Manager, UI / UX Designer). The split is captured per-role in the role file under a new `## Activation mode` section. The persona-marker convention (`▸ Activating Salim (QA Engineer) for #42 …`) is preserved on both sides.

## Consequences

### What ships across the 3 tickets

- **#347 PR 1-5** — 24 agent files (19 role-derived wraps + 5 utility) with framework default models from Axis 2; role-trigger integration per Axis 6; smoke test verifying wrap-shape compliance.
- **#351 PR 1-4** — YAML schema doc + lib resolver + SessionStart sync hook + drift-prevention guards + setup integration + local-routing schema entries (PR 4 gated on #348).
- **#348** — 2-day operator spike, output is a memo (promote → adds local entries to #351 schema; discard → spike memo documents what failed and why).
- **AgDR-0050 (this doc)** — referenced by the first PR of each ticket.

### What does NOT ship in v1

- **Mixed remote + local routing on one session**. Single-endpoint per session in v1; per-agent invocation env scoping deferred to v2.
- **Per-task / per-invocation model overrides**. `claude --model <m>` already exists for one-off; routing config is the persistent surface.
- **A web UI / CLI for editing the routing config**. Adopters edit YAML.
- **Auto-detection of local endpoints**. Adopters declare them.
- **Cost dashboards / per-agent usage tracking**. Separate concern; file if needed once running data exists.
- **Cross-region / multi-cloud routing rules**. Single endpoint per agent in v1.
- **Adopter-authored topology overrides** (cf. AgDR-0048's same v1 vs v2 split for topology-templates). Framework-curated defaults only; adopter customisation via routing config.

### Ongoing obligations

- **Routing config drift** — pre-commit + pre-push guards catch accidental commits of routing-config rewrites. Adopters who genuinely want a per-agent model edit at the framework default level (e.g. switching the framework's QA default from Haiku to Sonnet) submit it via PR; the guard accepts the new default once.
- **Model matrix updates** — the matrix in Axis 2 is reviewable as a framework PR (e.g. when a new Claude tier ships, or when Sonnet pricing changes shift the cost optimum). AgDR amend + agent file frontmatter update; routing-config consumers re-inherit.
- **Local-routing entries** — gated on #348's verdict. If local routing degrades adopter UX, the entries don't ship + the schema's `endpoint:` field remains for adopter override only.
- **Wave 1 invariants — skill count stable**, agent count grows from 5 to 24 in CLAUDE.md framework-integration row + the agent-count description; `test_token_efficiency_wave1.sh` should grow an agent-count check or the existing invariants explicitly tolerate the growth.
- **Role-file `## Activation mode` section** — every existing role gains the new section (sub-agent vs in-thread) as part of #347 PR 1's churn.

### Risks

- **Per-agent env-var scoping** — if `ANTHROPIC_BASE_URL` is session-scoped (not per-agent invocation), mixed remote + local on one session can't ship in v1. Mitigated by the v1 single-endpoint constraint and a clear v2 follow-up.
- **Drift guard false-positives** — adopter intentional one-off edits of an agent's model line get blocked. Mitigated by the `# routing-config:override <reason>` comment escape hatch.
- **YAML schema migration** — once shipped, adopters depend on the shape. Schema changes need deprecation flag + migration helper (same pattern as `apexyard.projects.yaml` shape changes).
- **Adopter forgets to re-session after editing the routing config** — clear UX from the SessionStart hook: one-line "5 agent overrides applied from agent-routing.yaml" banner at SessionStart. Silent on no-change.
- **Local-model output reliability** — even with #348 confirming feasibility for 3 candidates, model-update churn (Qwen / Llama / DeepSeek roll forward) may degrade. Mitigated by the routing-config edit-and-re-session cycle being fast.
- **Cost of running 22 sub-agents** vs in-thread persona adoption — each sub-agent spawn has cache-miss latency. Mitigated by the per-role model assignment paying for itself (Haiku QA, Opus SRE).

## PR plan (waves)

**Wave 1 — Foundation (post-AgDR-0050 merge, parallelisable):**

- #347 PR 1 — Engineering dept (7 agents: Khalid / Hisham / Karim / Yasmin / Salim / Adel / Saif) + role-file `## Activation mode` section additions across all 19 + smoke test
- #351 PR 1 — `agent-routing.yaml` schema doc + `portfolio_agent_routing` lib resolver + `docs/multi-project.md` setup section (no hook yet)

**Wave 2 — Spike runs in parallel with Wave 1:**

- #348 spike — 2 days operator hands-on (Ollama setup, model pulls, fixture runs, scoring). Output: a memo + recommended local-routing entries OR a "Claude-only" verdict.

**Wave 3 — Dependent on Wave 1:**

- #347 PR 2 — Product + Design (6 agents)
- #347 PR 3 — Security + Data (6 agents) + Hatim/Hakim consolidation decision
- #347 PR 4 — Utility-agent `model:` frontmatter (Rex / Hatim / Munir / Tariq / Idris)
- #351 PR 2 — SessionStart sync hook + drift smoke test + pre-commit guard
- #351 PR 3 — Setup integration (`/setup --split-portfolio` seeds the YAML; single-fork gitignore entry)

**Wave 4 — Dependent on Wave 2 + 3:**

- #347 PR 5 — Role-trigger integration (`detect-role-trigger.sh` switches from in-thread injection to sub-agent spawn for the isolated-work-class roles)
- #351 PR 4 — Local-routing entries in the seeded template (gated on #348 verdict)

**Total**: 10 PRs (+ 1 spike memo) across 3 tickets, all referencing AgDR-0050.

## Artifacts

- This AgDR file: `docs/agdr/AgDR-0050-agent-runtime-overhaul.md`
- Implementation tickets:
  - [#347 — Promote all 19 role definitions to Claude Code sub-agents](https://github.com/me2resh/apexyard/issues/347)
  - [#348 — Local-model routing feasibility spike](https://github.com/me2resh/apexyard/issues/348)
  - [#351 — Centralised agent-routing config](https://github.com/me2resh/apexyard/issues/351)
- Prior-art AgDRs:
  - [AgDR-0018 — persona naming convention](AgDR-0018-persona-naming-convention.md) — Rex / Hatim / Munir / Tariq / Idris naming + `persona_name` frontmatter field
  - [AgDR-0023 — custom-templates override semantics](AgDR-0023-custom-templates-override-semantics.md) — the closest prior-art for "adopter customisation layer that overrides framework defaults via path-mirroring"
  - [AgDR-0041 — SessionStart v2-anchor sweep](AgDR-0041-sessionstart-v2-anchor-sweep.md) — pattern for SessionStart-driven file rewrites + the `.apexyard-fork` marker model
  - [AgDR-0021 — split-portfolio v2 path resolution](AgDR-0021-split-portfolio-v2-path-resolution.md) — the private-repo-as-source-of-truth pattern this AgDR builds on
- Related role-system docs:
  - [`roles/`](../../roles/) — 19 persona definitions (the source-of-truth for Axis 1's wrap pattern)
  - [`.claude/rules/role-triggers.md`](../../.claude/rules/role-triggers.md) — the auto-activation table this AgDR's Axis 6 refines

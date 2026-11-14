# Role Triggers — When to Activate Which Role

ApexYard ships **12 role definitions** in `roles/{department}/`. They are not all loaded into every session (context efficiency — most of the files are idle during any given task). Instead, a role is **activated** when a specific condition is met: you read the role file, adopt its identity, responsibilities, and constraints for the duration of the task, then hand off to the next role in the chain.

AgDR-0301 reduced the roster from 23 agents to 15. Eight roles merged into five receivers, and their role files are redirect stubs for one release. There is no department-head role. Head-level approvals go to the **human approver**: the person that `.review_markers.human_approver_title` names (default `CEO`), who also records each per-PR merge approval. No agent approves its own work.

## Activation Table

| Role | File | Activate when… |
|------|------|----------------|
| **Tech Lead** | `roles/engineering/tech-lead.md` | Technical design for a new feature · planning phase in SDLC · code review approval gate · implementation task breakdown · architecture principles · new tech stack proposal · cross-project engineering call |
| **Solution Architect** | `roles/architecture/solution-architect.md` | A technical design / migration AgDR / feature spec is ready for review (before Build) · `/design-review` invoked · a PR carries a design artifact |
| **Backend Engineer** | `roles/engineering/backend-engineer.md` | Implementation phase on backend code (domain / application / infrastructure layers) · API work · database schema changes |
| **Frontend Engineer** | `roles/engineering/frontend-engineer.md` | Implementation phase on UI code · component work · design-system integration · accessibility review |
| **QA Engineer** | `roles/engineering/qa-engineer.md` | **Ticket enters QA state after merge** · optional `/code-review` pre-merge handoff after Rex approves · acceptance-criteria verification · bug triage · regression testing |
| **Platform Engineer** | `roles/engineering/platform-engineer.md` | CI/CD pipeline changes · developer tooling · infrastructure-as-code work · golden-path templates |
| **SRE** | `roles/engineering/sre.md` | Production incident · SLO breach · monitoring / alerting work · on-call rotation |
| **Product Manager** | `roles/product/product-manager.md` | PRD creation · user-story breakdown · acceptance-criteria authoring · sprint planning · roadmap prioritization · feasibility call · market research · competitive analysis |
| **UI Designer** | `roles/design/ui-designer.md` | Visual design · component specifications · design tokens · pixel-level work · design-system change · UX principles · user flows · information architecture · usability review · wireframing |
| **Security Auditor** | `roles/security/security-auditor.md` | **PR touches auth / crypto / user data / secrets** · **the security-critical trust chain (production `.claude/hooks/*.sh`, `.claude/settings.json`, `.githooks/*`, and delegated gate runner `bin/run-pre-push-checks.sh`) — #777/#1302** · SAST findings · OWASP review · dependency vulnerability · security strategy · threat model · compliance call |
| **Penetration Tester** | `roles/security/penetration-tester.md` | Active testing · exploit discovery · API security review · pre-release security sign-off |
| **Data Engineer** | `roles/data/data-engineer.md` | ETL pipelines · data modelling · data-quality work · warehouse schema changes · SQL queries · dashboards · A/B-test analysis · metric investigation · analytics strategy · data governance |

The old role titles still resolve. "Act as the Head of Product" activates the Product Manager, and each other old title activates its receiver:

| Old title | Receiver |
|-----------|----------|
| Head of Engineering | Tech Lead |
| Head of Product, Product Analyst | Product Manager |
| Head of Design, UX Designer | UI Designer |
| Head of Security | Security Auditor |
| Head of Data, Data Analyst | Data Engineer |

## Activation Protocol

When a trigger condition is met:

1. **Read the role file**: `@roles/{department}/{role}.md`
2. **Adopt the role's identity** — responsibilities, CAN / CANNOT constraints, interfaces
3. **Follow the handoff rules** defined in the role file — who you receive from, who you deliver to
4. **Stay in the role** until the task completes or a different trigger activates a different role

A single conversation can move through multiple roles. The SDLC for one feature typically chains:

```
Product Manager → UI Designer
  → Tech Lead → Solution Architect → Backend Engineer / Frontend Engineer
    → [Security Auditor if PR touches auth]
      → QA Engineer → Platform Engineer / SRE
```

Each handoff is explicit. The handing-off role delivers the artefact defined in its role file (PRD, tech design, PR, test plan, etc.); the receiving role reads it and moves forward.

### On inbound escalation

An escalation that needs a head-level decision goes to the human approver, not to an agent. The escalating role stops and states the decision it needs, its recommendation, and the reason. The human approver decides, and work resumes where it paused. Each role file's `## Escalate When` section lists what it escalates.

| Receiver | Decision that goes to the human approver | Independent review that stays |
|----------|------------------------------------------|-------------------------------|
| Product Manager (Mariam) | PRDs, new ideas, material roadmap changes | Tariq reviews the design. Anwar checks quantitative claims. |
| Tech Lead (Hisham) | New stacks, architecture principles, major designs | Tariq. Tariq's escalations go to the human approver, not to Hisham. |
| UI Designer (Nour) | Design-system and brand changes, design disputes | Salim (flows, browser evidence). Mariam (journeys against the PRD). |
| Security Auditor (Hakim) | Exceptions to security requirements, risk acceptance | Rex. Hakim keeps read-only tools. |
| Data Engineer (Anwar) | Data architecture and policy exceptions | Tariq (architecture, migration AgDRs). The migration gate does not change. Hakim (access and privacy). |

### How to signal activation

When you activate, hand off, or exit a role, print a single-line marker at the top of your response. The reader sees who's driving the work right now.

**Activation** — when entering a role:

```
▸ Activating Salim (QA Engineer) for #42 (trigger: ticket labeled `qa`)
```

**Handoff** — when one role hands off to another:

```
▸ Salim (QA Engineer) → Mariam (Product Manager) (handoff: acceptance criteria signed off)
```

**Exit** — when finishing a role and returning to ambient mode:

```
▸ Salim (QA Engineer) task complete — returning to ambient mode
```

**Main thread route** — Hadi prints a marker only when it routes work to a role. Hadi does not print a marker for ordinary work.

```
▸ Hadi routes #42 to Rex (code review)
▸ Hadi routes #42 to Salim (QA Engineer) (trigger: ticket labeled qa)
```

The persona name comes from the `persona_name` field added in [#204](https://github.com/me2resh/apexyard/issues/204). If a future role doesn't have a persona name (custom adopter role), drop the name and use just the title (e.g. `▸ Activating QA Engineer for #42 …`). The triangle prefix (`▸`) makes the marker visually scannable.

This is a **prose convention**, not a mechanically-enforced format. The sibling hook (`detect-role-trigger.sh`, from [#206](https://github.com/me2resh/apexyard/issues/206)) already injects an advisory reminder banner when a trigger fires; this convention adds the agent's response side so operators can see the transition in the conversation.

## Trigger Types

**Auto-activation** — a role should activate automatically when its condition is detected in conversation context:

| Signal | Activate |
|--------|----------|
| Ticket moved to `qa` label | QA Engineer |
| PR diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*` | Security Auditor |
| Edit/PR touches the trust chain — production `.claude/hooks/*.sh` (merge gates, tracker/forge lib, review-marker lib, credential-broker scripts), `.claude/settings.json` (the matcher wiring that decides whether a gate fires), `.githooks/*`, or a delegated gate runner such as `bin/run-pre-push-checks.sh` | Security Auditor (#777, #1302) |
| PR diff touches `.github/workflows/**`, `golden-paths/pipelines/**` | Platform Engineer |
| PR diff touches `docs/agdr/**` or adds a new dependency | Tech Lead |
| Edit/PR touches a design artifact (technical design, migration AgDR, feature spec / PRD) | Solution Architect |
| Production incident / SLO breach mentioned | SRE |
| New PRD or spec being drafted | Product Manager |
| Roadmap question or prioritization call | Product Manager |
| User flow / wireframe / IA question | UI Designer |
| Component spec / design tokens question | UI Designer |
| Cross-project strategy question | The receiver for that discipline (Tech Lead, Product Manager, UI Designer, Security Auditor, or Data Engineer). The human approver makes the decision. |

**Prompted activation** — the user explicitly asks for a role:

```
"Act as the QA Engineer and verify ticket #42"
"Put on your Tech Lead hat and review this PR"
"As the Security Auditor, check this PR for OWASP issues"
```

Both forms result in the role file being read and the role being embodied for the task.

## Role Boundaries

Every role file defines CAN / CANNOT lists. When active in a role, respect those boundaries strictly:

- A Backend Engineer **cannot** add new technologies without Tech Lead approval
- A Tech Lead **cannot** add a new technology or change an architecture principle without the human approver
- A QA Engineer **cannot** approve code merges (only comment)
- A Product Manager **cannot** make technical architecture calls

When you hit a CANNOT, hand off to the role that can.

## Handoff Artefacts

Roles deliver concrete artefacts at each handoff point. These are the contracts between roles — if the artefact isn't ready, the next role can't start.

| From → To | Artefact |
|-----------|----------|
| Product Manager → Tech Lead | Approved PRD with acceptance criteria |
| Tech Lead → Solution Architect | Authored technical design / migration AgDR / feature spec to review |
| Solution Architect → Tech Lead / Engineers | Design review + sign-off (the Design→Build gate) |
| UI Designer → Frontend Engineer | Component specs + design tokens, user flows + wireframes |
| UI Designer → Human approver | Escalated design call (design-system change · brand change · cross-product visual standard · design disagreement) |
| Tech Lead → Backend / Frontend Engineer | Technical design + task breakdown |
| Backend / Frontend Engineer → QA Engineer | Testable build + PR |
| Security Auditor → Tech Lead | Security findings + required fixes (remediation is engineering work) |
| Security Auditor → Human approver | Risk acceptance · exception to a security requirement · release block recommendation |
| QA Engineer → Product Manager | AC verification sign-off |
| Platform Engineer → SRE | Production deployment + runbook |

### Two authority splits worth calling out

Two of the rows above encode a **practitioner-reviews / human-decides** split. AgDR-0301 supersedes the earlier head-escalates split of AgDR-0106:

- **UI design gate.** The **UI Designer (Nour)** owns the routine per-PR design gate. She reviews the implementation diff, and a person records the verdict with `/approve-design` (gated by `require-design-review-for-ui.sh`). A design-system change, a brand change, a cross-product visual standard, or a design disagreement goes to the human approver.
- **Security escalation.** A **Security Auditor's findings + required fixes go to the Tech Lead** — remediation is engineering work. Hakim also owns the security posture: strategy, threat models, and compliance. Risk acceptance and exceptions to security requirements go to the human approver. Hakim keeps read-only tools.

## Aspirational → Real

Before this rule existed, the 19 role files were passive markdown docs — no trigger, no activation, no automatic reference from workflows or skills. A user had to manually say *"please read `roles/engineering/qa-engineer.md` and act as the QA Engineer"* for anything to happen.

This file closes that gap. When in a Claude Code session under apexyard, the trigger table drives which role activates, and the workflow and skill files now explicitly reference the role files at every phase boundary. Roles are now **first-class participants** in the SDLC, not reference material.

### Mechanical backstop — `detect-role-trigger.sh`

Self-discipline (the agent remembering to read the role file when the rule fires) is the primary mechanism. The framework also ships a mechanical backstop: `.claude/hooks/detect-role-trigger.sh` scans for trigger conditions on every relevant tool call and emits a system-reminder-style banner naming the role + the file to read.

Same advisory shape as `check-upstream-drift.sh` — non-blocking, exit 0 always. The banner cannot force the agent to adopt the role, but it removes the "I forgot the rule applied here" failure mode.

#### Class-aware banner (HYBRID, AgDR-0050 § Axis 6 — live since #347 PR 5)

Each banner reads the matched role's `**Class**:` value from the `## Activation mode` section of the role file and emits one of two shapes:

- **Isolated-work-class** (6 roles: Tech Lead, Solution Architect, QA Engineer, SRE, Security Auditor, Pen Tester): the banner instructs the agent to **SPAWN the sub-agent via the Agent tool** with `subagent_type: <slug>`, naming both the canonical role file at `roles/<dept>/<role>.md` and the agent wrapper at `.claude/agents/<slug>.md`. Per AgDR-0050 § Axis 6, isolated work benefits from isolated context + tool restriction.
- **In-flow-class** (6 roles: Backend / Frontend / Platform Engineer, Product Manager, UI Designer, Data Engineer): the banner instructs the agent to **adopt the persona IN-THREAD** by reading `roles/<dept>/<role>.md`. Per AgDR-0050 § Axis 6, in-flow work loses too much shared context if spawned out-of-thread.

One naming exception: the Security Auditor role (`roles/security/security-auditor.md`) maps to the `security-reviewer` agent slug, not `security-auditor`. This is the Hatim→Hakim consolidation from PR #360 — the agent filename was preserved so `/security-review` and the auto-fire trigger keep working. The hook handles the exception via `agent_slug_for()`.

The class lookup is conservative: if the role file is missing or the `**Class**:` line can't be parsed, the banner falls back to in-flow-class shape. Better to under-trigger sub-agent spawn than to incorrectly suggest one for an unclassified role.

Triggers wired in v1 (me2resh/apexyard#206):

| Trigger family | Hook event | Detection | Role |
|----------------|------------|-----------|------|
| Label-based  | `PreToolUse` on `Bash` (matcher: `gh issue edit *`) | `--add-label qa` (single or comma list) | QA Engineer |
| Diff/path    | `PreToolUse` on `Edit` / `Write` / `MultiEdit` | path contains `auth/`, `crypto/`, `secrets/`, `.env*` | Security Auditor |
| Diff/path    | same | path under `.claude/hooks/`, `.githooks/`, or matches `.claude/settings.json` and delegated gate runners such as `bin/run-pre-push-checks.sh` (the trust chain — #777, #1302) | Security Auditor |
| Diff/path    | same | path under `.github/workflows/` or `golden-paths/pipelines/` | Platform Engineer |
| Diff/path    | same | path under `docs/agdr/` | Tech Lead |
| Diff/path    | same | path matches a design artifact (`*technical-design*.md`, `*tech-design*.md`, `**/designs/**`, `**/prds/**`, `*prd*.md`, `*feature-spec*.md`, `docs/agdr/*migration*.md`) | Solution Architect |
| Prompted     | `UserPromptSubmit` | "act as the X" / "as the X" / "put on your X hat" (case-insensitive, X matches any role in the activation table) | the named role |

A migration AgDR fires **both** the Tech Lead trigger (`docs/agdr/**`, author) and the Solution Architect trigger (`docs/agdr/*migration*.md`, reviewer) — the two are additive by design: Hisham authors, Tariq reviews.

Triggers from the table above that are **not** yet mechanically detected (e.g. "production incident mentioned" → SRE, "new PRD drafted" → Product Manager) still rely on self-discipline; the hook can be extended without changing the surrounding wiring.

Tests live at `.claude/hooks/tests/test_detect_role_trigger.sh` and cover the three trigger families the acceptance criteria call out.

---

### The Contrarian (utility agent — premise-level adversary)

Naqid (The Contrarian) is a **utility agent**, not a department role — like Rex (`code-reviewer`) and Tariq (`solution-architect`), it isn't tied to an SDLC phase and has no department file under `roles/`. It challenges the **premise** of an idea/feature/spec/decision/plan, and is **advisory-only** (no marker, no gate). It does **not** auto-fire on diffs — challenging a premise is a human-initiated act, so **prompted activation** is the primary path. The phrases below are mechanically detected by `detect-role-trigger.sh` (which emits an advisory banner suggesting `/challenge`).

| Signal | Activate |
|--------|----------|
| `/challenge <target>` | The Contrarian (Naqid) |
| "play devil's advocate on …" / "challenge this" / "poke holes in …" / "what's the case against …" / "steelman then attack …" | The Contrarian (Naqid) |

**Optional advisory offer (never forced).** At high-stakes moments — a new AgDR via `/decide`, a new PRD via `/write-spec`, or plan-mode exit on a large call — you MAY surface a one-line nudge offering to run `/challenge` first. The operator opts in; never auto-run it, and never let its verdict block work (it informs, it doesn't veto). See `.claude/agents/contrarian.md`, `.claude/skills/challenge/SKILL.md`, and AgDR-0078.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

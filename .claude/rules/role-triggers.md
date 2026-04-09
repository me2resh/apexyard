# Role Triggers — When to Activate Which Role

ApexStack ships **19 role definitions** in `roles/{department}/`. They are not all loaded into every session (context efficiency — 19 files × ~120 lines averages out to ~22k tokens, most of which are idle during any given task). Instead, a role is **activated** when a specific condition is met: you read the role file, adopt its identity, responsibilities, and constraints for the duration of the task, then hand off to the next role in the chain.

## Activation Table

| Role | File | Activate when… |
|------|------|----------------|
| **Head of Engineering** | `roles/engineering/head-of-engineering.md` | Architecture review requested · new tech stack addition · cross-project engineering call · escalation from a Tech Lead |
| **Tech Lead** | `roles/engineering/tech-lead.md` | Technical design for a new feature · planning phase in SDLC · code review approval gate · implementation task breakdown |
| **Backend Engineer** | `roles/engineering/backend-engineer.md` | Implementation phase on backend code (domain / application / infrastructure layers) · API work · database schema changes |
| **Frontend Engineer** | `roles/engineering/frontend-engineer.md` | Implementation phase on UI code · component work · design-system integration · accessibility review |
| **QA Engineer** | `roles/engineering/qa-engineer.md` | **Ticket enters QA state after merge** · acceptance-criteria verification · bug triage · regression testing |
| **Platform Engineer** | `roles/engineering/platform-engineer.md` | CI/CD pipeline changes · developer tooling · infrastructure-as-code work · golden-path templates |
| **SRE** | `roles/engineering/sre.md` | Production incident · SLO breach · monitoring / alerting work · on-call rotation |
| **Head of Product** | `roles/product/head-of-product.md` | Roadmap prioritization · feasibility call · strategic product decision · resource allocation across products |
| **Product Manager** | `roles/product/product-manager.md` | PRD creation · user-story breakdown · acceptance-criteria authoring · sprint planning |
| **Product Analyst** | `roles/product/product-analyst.md` | Market research · competitive analysis · metric investigation · data-driven product call |
| **Head of Design** | `roles/design/head-of-design.md` | Design-system changes · UX principles decision · cross-project visual standards |
| **UI Designer** | `roles/design/ui-designer.md` | Visual design · component specifications · design tokens · pixel-level work |
| **UX Designer** | `roles/design/ux-designer.md` | User flows · information architecture · usability review · wireframing |
| **Head of Security** | `roles/security/head-of-security.md` | Security strategy · threat model · compliance call · cross-project security architecture |
| **Security Auditor** | `roles/security/security-auditor.md` | **PR touches auth / crypto / user data / secrets** · SAST findings · OWASP review · dependency vulnerability |
| **Penetration Tester** | `roles/security/penetration-tester.md` | Active testing · exploit discovery · API security review · pre-release security sign-off |
| **Head of Data** | `roles/data/head-of-data.md` | Analytics strategy · data governance · reporting architecture · cross-project data modelling |
| **Data Analyst** | `roles/data/data-analyst.md` | SQL queries · dashboards · A/B-test analysis · metric investigation |
| **Data Engineer** | `roles/data/data-engineer.md` | ETL pipelines · data modelling · data-quality work · warehouse schema changes |

## Activation Protocol

When a trigger condition is met:

1. **Read the role file**: `@roles/{department}/{role}.md`
2. **Adopt the role's identity** — responsibilities, CAN / CANNOT constraints, interfaces
3. **Follow the handoff rules** defined in the role file — who you receive from, who you deliver to
4. **Stay in the role** until the task completes or a different trigger activates a different role

A single conversation can move through multiple roles. The SDLC for one feature typically chains:

```
Head of Product → Product Manager → Head of Design / UX Designer / UI Designer
  → Tech Lead → Backend Engineer / Frontend Engineer
    → [Security Auditor if PR touches auth]
      → QA Engineer → Platform Engineer / SRE
```

Each handoff is explicit. The handing-off role delivers the artefact defined in its role file (PRD, tech design, PR, test plan, etc.); the receiving role reads it and moves forward.

## Trigger Types

**Auto-activation** — a role should activate automatically when its condition is detected in conversation context:

| Signal | Activate |
|--------|----------|
| Ticket moved to `qa` label | QA Engineer |
| PR diff touches `**/auth/**`, `**/crypto/**`, `**/secrets/**`, `.env*` | Security Auditor |
| PR diff touches `.github/workflows/**`, `golden-paths/pipelines/**` | Platform Engineer |
| PR diff touches `docs/agdr/**` or adds a new dependency | Tech Lead |
| Production incident / SLO breach mentioned | SRE |
| New PRD or spec being drafted | Product Manager |
| Roadmap question or prioritization call | Head of Product |
| User flow / wireframe / IA question | UX Designer |
| Component spec / design tokens question | UI Designer |
| Cross-project strategy question | The relevant Head of _ role |

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
- A Tech Lead **cannot** override Head of Engineering decisions
- A QA Engineer **cannot** approve code merges (only comment)
- A Product Manager **cannot** make technical architecture calls

When you hit a CANNOT, hand off to the role that can.

## Handoff Artefacts

Roles deliver concrete artefacts at each handoff point. These are the contracts between roles — if the artefact isn't ready, the next role can't start.

| From → To | Artefact |
|-----------|----------|
| Product Manager → Tech Lead | Approved PRD with acceptance criteria |
| Head of Design → UX/UI Designer | Design system tokens + principles |
| UX Designer → UI Designer | User flows + wireframes |
| UI Designer → Frontend Engineer | Component specs + design tokens |
| Tech Lead → Backend / Frontend Engineer | Technical design + task breakdown |
| Backend / Frontend Engineer → QA Engineer | Testable build + PR |
| Security Auditor → Tech Lead | Security findings + required fixes |
| QA Engineer → Product Manager | AC verification sign-off |
| Platform Engineer → SRE | Production deployment + runbook |

## Aspirational → Real

Before this rule existed, the 19 role files were passive markdown docs — no trigger, no activation, no automatic reference from workflows or skills. A user had to manually say *"please read `roles/engineering/qa-engineer.md` and act as the QA Engineer"* for anything to happen.

This file closes that gap. When in a Claude Code session under apexstack, the trigger table drives which role activates, and the workflow and skill files now explicitly reference the role files at every phase boundary. Roles are now **first-class participants** in the SDLC, not reference material.

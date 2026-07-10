# What's Inside ApexYard

The full component breakdown — directory layout, every role, the workflow docs, the templates, and the runnable `.claude/` layer (hooks, rules, agents, skills). The [README](../README.md) keeps a lean summary; this is the exhaustive reference.

All of it is plain markdown and shell. There is no runtime and no service — Claude Code reads these files directly, and the hooks fire on your `git` / `gh` commands.

## Directory layout

```
apexyard/
├── CLAUDE.md              # Stack entry point -- Claude Code reads this first
├── onboarding.yaml        # Your company config -- fill this in to adopt the stack
│
├── roles/                 # AI agent role definitions (20 across 6 departments)
│   ├── engineering/       # Backend, Frontend, QA, Platform, SRE, Tech Lead, Head of Eng
│   ├── architecture/      # Solution Architect (Tariq)
│   ├── product/           # Product Manager, Product Analyst, Head of Product
│   ├── design/            # UI Designer, UX Designer, Head of Design
│   ├── security/          # Security Auditor, Penetration Tester, Head of Security
│   └── data/              # Data Analyst, Data Engineer, Head of Data
│
├── workflows/             # Development lifecycle processes
│   ├── sdlc.md            # Full SDLC including the database-migration sub-workflow
│   ├── code-review.md     # Code review process and standards
│   └── deployment.md      # Environment promotion, rollback, IaC patterns
│
├── templates/             # Reusable document templates
│   ├── prd.md             # Product Requirements Document
│   ├── technical-design.md # Technical design document
│   ├── adr.md             # Architecture Decision Record
│   ├── agdr.md            # Agent Decision Record (AI-specific)
│   ├── agdr-migration.md  # Migration-specific AgDR (rollback, downtime, consumers)
│   └── architecture/      # C4 diagram templates — Context (L1) + Container (L2), Mermaid
│
├── .claude/               # Claude Code primitives (the runnable layer)
│   ├── settings.json      # Hook wiring (PreToolUse, PostToolUse, SessionStart)
│   ├── hooks/             # 42 shell scripts — ticket-first, migration gate, two-marker merge gate, red-CI block, secrets scan, branch/PR validation, leak protection, MCP-reindex advisories, upstream-drift banner
│   ├── rules/             # 15 modular rule files imported via @.claude/rules/*
│   ├── agents/            # 25 sub-agents — Rex (Code Reviewer), Hakim (Security Auditor), Tariq (Solution Architect), the engineering / product / design / data / security personas, plus utility agents (PR & ticket managers, dependency auditor, The Contrarian)
│   └── skills/            # 64 slash commands — see CLAUDE.md for the full list
│
├── workspace/             # Live local clones of managed projects — gitignored
├── projects/              # Per-project committed docs (README, roadmap, AgDRs, updates)
├── apexyard.projects.yaml.example  # Portfolio registry template
│
├── golden-paths/          # Reusable infra & ops templates
│   └── pipelines/         # Drop-in GitHub Actions workflows (CI, code quality, Swift CI, security, dependency audit, PR title check, review check, SEO check)
│
└── docs/                  # Documentation
    ├── getting-started.md # Setup guide
    ├── multi-project.md   # Full setup guide (fork flow, directory layout, daily workflow, FAQ)
    └── whats-inside.md    # This file — the full component breakdown
```

## Roles

ApexYard includes 20 software-development roles across 6 departments. Roles are not passive docs — they **activate on triggers** (a PR touching `**/auth/**` fires the Security Auditor; a ticket labelled `qa` fires the QA Engineer). See [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md) for the full activation table.

### Engineering (7 roles)

- **Head of Engineering** -- Technical strategy, architecture standards, quality
- **Tech Lead** -- Feature design, code review, team coordination
- **Backend Engineer** -- Domain logic, APIs, infrastructure
- **Frontend Engineer** -- UI components, design system, accessibility
- **QA Engineer** -- Test strategy, automation, quality gates
- **Platform Engineer** -- CI/CD, infrastructure as code, developer tooling
- **Site Reliability Engineer** -- Monitoring, incidents, SLOs

### Architecture (1 role)

- **Solution Architect** (Tariq) -- Independent design review before Build: NFRs, patterns, tech-debt, risk, traceability — the non-code analog of the Code Reviewer

### Product (3 roles)

- **Head of Product** -- Roadmap, prioritization, feasibility
- **Product Manager** -- PRDs, user stories, acceptance criteria
- **Product Analyst** -- Market research, metrics, competitive analysis

### Design (3 roles)

- **Head of Design** -- Design system, UX principles, visual standards
- **UI Designer** -- Visual design tokens, component specifications
- **UX Designer** -- User flows, information architecture, usability

### Security (3 roles)

- **Head of Security** -- Security strategy, threat modeling, compliance
- **Security Auditor** -- Static analysis, vulnerability detection, OWASP
- **Penetration Tester** -- Active testing, exploit discovery, API security

### Data (3 roles)

- **Head of Data** -- Analytics strategy, data governance, reporting
- **Data Analyst** -- SQL, dashboards, A/B testing, metrics
- **Data Engineer** -- ETL pipelines, data modeling, data quality

## Workflows

### Software Development Lifecycle (SDLC)

```
Planning --> Design --> Build --> Review --> QA --> Deploy --> Monitor
```

Each phase has entry criteria, activities, exit criteria, and quality gates. See [`workflows/sdlc.md`](../workflows/sdlc.md) for the full flow.

### Code Review Process

Structured review with:

- Author responsibilities and PR description format
- Reviewer checklist (architecture, security, testing, performance)
- Feedback severity levels (blocking, suggestion, question)
- Response time targets
- Rex (code-reviewer agent) auto-runs on every PR; human reviewer activates per role triggers

See [`workflows/code-review.md`](../workflows/code-review.md).

### Deployment Process

- Infrastructure as Code patterns
- CI/CD pipeline stages
- Environment promotion (staging → production)
- Rollback procedures

See [`workflows/deployment.md`](../workflows/deployment.md) for the full flow.

### Database Migration Sub-Workflow

Migrations are high-blast-radius work and get their own gate (workflow gate 3a). Any edit to `migrate-*.{ts,js,py,sql}`, `**/migrations/**`, `prisma/schema.prisma`, `alembic/versions/*`, or similar requires:

1. A labelled `migration` ticket
2. A matching migration AgDR that documents rollback, estimated downtime, cross-service consumers, data volume, testing plan, observability

The `/migration` skill creates both artefacts in one guided flow; the `require-migration-ticket.sh` hook blocks edits to migration paths until they exist.

## Templates

| Template | Purpose |
|----------|---------|
| PRD | Product Requirements Document with user stories, acceptance criteria |
| Technical Design | Architecture, domain model, API design, implementation plan |
| ADR | Architecture Decision Record for significant technical decisions |
| AgDR | Agent Decision Record — AI-specific decision tracking |
| Migration AgDR | Migration-specific AgDR — rollback plan, downtime estimate, consumers, observability |
| C4 Context (L1) | System context Mermaid diagram — external actors + system boundary |
| C4 Container (L2) | Container Mermaid diagram — deployable units inside the system |

## The `.claude/` layer — the runnable primitives

This is what turns the markdown above into an enforced workflow. Claude Code picks it up automatically when the `.claude/` directory lives at the repo root.

| Layer | Path | What it is |
|-------|------|------------|
| **Hooks** | `.claude/hooks/` | 43 shell scripts that mechanically enforce SDLC rules — ticket-first edits (Edit/Write/Bash), migration-ticket-first, auto code review, merge gates (Rex + CEO + design + architecture review), red-CI block, commit-format, AgDR-for-arch-changes, branch/PR-title validation, secrets scanning, private-ref leak protection, upstream-drift banner, MCP-reindex advisories |
| **Rules** | `.claude/rules/` | 15 modular rule files imported via `@.claude/rules/*` from `CLAUDE.md` |
| **Agents** | `.claude/agents/` | 25 sub-agents — the department personas plus utility agents |
| **Skills** | `.claude/skills/` | 64 slash commands |
| **Settings** | `.claude/settings.json` | Wires hooks to `PreToolUse`, `PostToolUse`, and `SessionStart` events |

### The 15 rule files

`agdr-decisions`, `agent-role-selection`, `code-standards`, `git-conventions`, `isolated-builds`, `leak-protection`, `loop-mode`, `parallel-work`, `plan-mode`, `pr-quality`, `pr-workflow`, `reporting-style`, `role-triggers`, `ticket-vocabulary`, `workflow-gates`.

### The 25 sub-agents

Utility agents: **Rex** (`code-reviewer`), **Hakim** (`security-reviewer`), **Tariq** (`solution-architect`), **Naqid** (`contrarian`), plus `pr-manager`, `ticket-manager`, and `dependency-auditor`. The remaining 18 are the department-role agents (engineering, product, design, security, data — one per role file).

### The 64 skills

The full, one-line-per-skill list lives in [`CLAUDE.md`](../CLAUDE.md) under "Available skills". Highlights by category:

- **Bootstrap & sync** — `/setup`, `/handover`, `/update`, `/split-portfolio`
- **Planning & tickets** — `/write-spec`, `/plan-initiative`, `/feature`, `/bug`, `/task`, `/tickets-batch`, `/spike`, `/prototype`, `/walking-skeleton`, `/migration`, `/investigation`, `/idea`
- **Review & decisions** — `/decide`, `/agdr`, `/code-review`, `/security-review`, `/design-review`, `/challenge`, `/approve-merge`, `/approve-design`, `/approve-architecture`
- **Audits** — `/launch-check`, `/threat-model`, `/accessibility-audit`, `/compliance-check`, `/analytics-audit`, `/seo-audit`, `/geo-audit`, `/performance-audit`, `/monitoring-audit`, `/docs-audit`, `/mutation-test`, `/audit-deps`
- **Architecture & diagrams** — `/c4`, `/dfd`, `/tech-vision`, `/journey`, `/feature-diagram`, `/extract-features`, `/process`
- **Portfolio** — `/projects`, `/inbox`, `/status`, `/tasks`, `/roadmap`, `/stakeholder-update`, `/fan-out`

## CI/CD pipelines

Reusable GitHub Actions workflows live at `golden-paths/pipelines/`:

| Pipeline | Purpose |
|----------|---------|
| `ci.yml` | Combined pipeline (code quality + security + dependencies) |
| `code-quality.yml` | TypeScript, ESLint, tests, build |
| `swift-ci.yml` | Swift Package Manager build + guarded test (macOS) |
| `security.yml` | Semgrep SAST + npm audit + secrets detection |
| `dependency-audit.yml` | Weekly vulnerability + license scan |
| `pr-title-check.yml` | Enforce ticket ID in PR titles |
| `review-check.yml` | Block merge if Code Reviewer hasn't reviewed the latest commit |
| `seo-check.yml` | SEO analysis for content files |

Copy whichever you need into your project's `.github/workflows/`. Full details in `golden-paths/pipelines/README.md`.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

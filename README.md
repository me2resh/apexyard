# ApexYard

**Where projects get forged.**

A multi-project ops repo where your projects reference each other, learn from shared experience, and ship production-ready under a strict SDLC. Built for founders who ship alone, or companies standing up AI-enabled squads.

You don't *add* apexyard to a project — projects get forged *inside* it. One ops repo. Every product. Shared memory. Strict gates. Production-ready MVPs.

Claude Code is the default driver, but the rules, hooks, and templates are plain markdown and shell. Swap the AI. Keep the forge. No SaaS. No lock-in.

**Proven shipping** TypeScript + AWS Lambda backends, Next.js web apps, Chrome extensions, and native **Swift** macOS desktop apps. The stack is process and guardrails — not a language or framework lock-in.

Inspired by [gstacks.org](https://gstacks.org/) — but purpose-built for software teams running more than one product at a time.

## What's Inside

```
apexyard/
├── CLAUDE.md              # Stack entry point -- Claude Code reads this first
├── onboarding.yaml        # Your company config -- fill this in to adopt the stack
│
├── roles/                 # AI agent role definitions
│   ├── engineering/       # Backend, Frontend, QA, Platform, SRE, Tech Lead, Head of Eng
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
│   ├── hooks/             # 18 shell scripts — ticket-first, migration gate, two-marker merge gate, red-CI block, secrets scan, branch/PR validation, upstream-drift banner
│   ├── rules/             # 8 modular rule files imported via @.claude/rules/* (agdr-decisions, code-standards, git-conventions, pr-quality, pr-workflow, role-triggers, ticket-vocabulary, workflow-gates)
│   ├── agents/            # 5 sub-agents — Code Reviewer (Rex), Security Reviewer (Shield), Dependency Auditor (Guardian), PR Manager, Ticket Manager
│   └── skills/            # 33 slash commands — see CLAUDE.md for the full list
│
├── workspace/             # Live local clones of managed projects — gitignored
├── projects/              # Per-project committed docs (README, roadmap, AgDRs, updates)
├── apexyard.projects.yaml.example  # Portfolio registry template
│
├── golden-paths/          # Reusable infra & ops templates
│   └── pipelines/         # Drop-in GitHub Actions workflows (CI, code quality, security, dependency audit, PR title check, review check, SEO check)
│
├── docs/                  # Documentation
│   ├── getting-started.md # Setup guide
│   └── multi-project.md   # Full setup guide (fork flow, directory layout, daily workflow, FAQ)
│
└── site/                  # Landing page
    └── index.html
```

## Quick Start — fork and go

ApexYard governs a **portfolio of repos** as one organisation. You fork apexyard, clone the fork, treat it as your "ops repo", and register every project you want under management. No `.apexyard/` symlinks, no nested installs — the fork IS the ops repo.

### 1. Star + Fork on GitHub

Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard), **Star** it, then **Fork** it into your org. You can keep the fork named `apexyard` or rename to something that fits your naming convention (`your-org/ops`, `your-org/apex`, etc.).

### 2. Clone your fork locally

```bash
gh repo clone your-org/apexyard
cd apexyard
```

Or with plain git:

```bash
git clone https://github.com/your-org/apexyard.git
cd apexyard
```

### 3. Add `upstream` for future updates

```bash
git remote add upstream https://github.com/me2resh/apexyard.git
```

Later, `git fetch upstream && git merge upstream/main` pulls the latest apexyard improvements into your fork.

### 4. Fill in `onboarding.yaml`

```bash
$EDITOR onboarding.yaml
```

Set company, team, tech stack, quality bar. Defaults are sensible — change what matters for your team.

### 5. Create the portfolio registry

```bash
cp apexyard.projects.yaml.example apexyard.projects.yaml
$EDITOR apexyard.projects.yaml   # list every repo you manage
```

The minimal entry is:

```yaml
version: 1
projects:
  - name: example-app
    repo: your-org/example-app
    docs: projects/example-app
    status: active
```

Even if you have just one repo, register it — the skills are happier with one registered project than with a dangling "assume the current directory" fallback.

### 6. Start working

```
/projects          # list every managed project + status
/inbox             # PRs, issues, comments needing your attention
/status            # git + CI snapshot per project
/decide            # make a technical decision (creates an AgDR)
```

The hooks fire on every `git` / `gh` command, the portfolio skills aggregate across the registry, and the Code Reviewer agent can be invoked with `/code-review <pr>`.

Full setup guide with directory layout, daily workflow, and FAQ: [`docs/multi-project.md`](docs/multi-project.md).

## Why ApexYard?

**The problem**: Claude Code is powerful, but without structure it produces inconsistent results. Every team reinvents the same processes -- role definitions, review checklists, document templates, workflow gates.

**The solution**: ApexYard provides that structure as a reusable, open-source stack. One config file to customize, 19 role definitions to use, battle-tested workflows to follow, and 18 shell hooks that enforce the rules mechanically.

### What makes it different

| Feature | Without ApexYard | With ApexYard |
|---------|-------------------|----------------|
| Code reviews | Ad-hoc prompts | Rex agent on every PR, SHA-bound approval marker |
| Technical decisions | Lost in chat history | Documented as Agent Decision Records |
| Quality gates | Hope and pray | 18 shell hooks block bad commits, forged markers, unreviewed merges |
| Merge approval | Informal "LGTM" | Two-marker gate — Rex (code) + CEO (per-PR explicit) |
| Database migrations | Drop-column-on-Friday | Dedicated gate: labelled ticket + migration AgDR (rollback, downtime, consumers) required before schema edits |
| Architecture docs | Nobody draws them | C4 L1 + L2 Mermaid templates + `/c4` skill generates stubs from a codebase |
| Portfolio visibility | Tab through 5 GitHubs | `/inbox`, `/status`, `/tasks` aggregate across a single registry file |
| Upstream sync | Forget for 6 months | Session-start drift banner + `/update` skill |
| Role consistency | Re-explain every session | Persistent role definitions, activation-triggered |
| Onboarding | Days of context-setting | `/setup` three-exchange config |

## Roles

ApexYard includes 19 software development roles across 5 departments:

### Engineering (7 roles)

- **Head of Engineering** -- Technical strategy, architecture standards, quality
- **Tech Lead** -- Feature design, code review, team coordination
- **Backend Engineer** -- Domain logic, APIs, infrastructure
- **Frontend Engineer** -- UI components, design system, accessibility
- **QA Engineer** -- Test strategy, automation, quality gates
- **Platform Engineer** -- CI/CD, infrastructure as code, developer tooling
- **Site Reliability Engineer** -- Monitoring, incidents, SLOs

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

Each phase has entry criteria, activities, exit criteria, and quality gates. See [`workflows/sdlc.md`](workflows/sdlc.md) for the full flow.

### Code Review Process

Structured review with:

- Author responsibilities and PR description format
- Reviewer checklist (architecture, security, testing, performance)
- Feedback severity levels (blocking, suggestion, question)
- Response time targets
- Rex (code-reviewer agent) auto-runs on every PR; human reviewer activates per role triggers

### Deployment Process

- Infrastructure as Code patterns
- CI/CD pipeline stages
- Environment promotion (staging → production)
- Rollback procedures

See [`workflows/deployment.md`](workflows/deployment.md) for the full flow.

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

## Customization

ApexYard is designed to be customized. Every role, workflow, and template can be modified to fit your team:

1. **Add roles**: Create new `.md` files in `roles/your-department/`
2. **Modify workflows**: Edit files in `workflows/`
3. **Add templates**: Drop new templates in `templates/`
4. **Override anything**: The stack is just markdown files -- edit freely

## Contributing

Contributions are welcome. ApexYard itself runs on its own rules, so the flow is the same one you'd use for any project under ApexYard governance:

1. **File a ticket** — `/feature`, `/bug`, or `/task` on this repo. Describes what you want to change and why.
2. **Start the ticket** — `/start-ticket <number>` so the ticket-first hook lets your code edits through.
3. **Branch + commit** — `{type}/GH-{number}-{short-description}`, conventional commit format (`type(#number): subject`).
4. **Self-check before pushing** — `npm run lint` / markdownlint / shellcheck as applicable; hooks remind you at `git push`.
5. **Open a PR** — title `type(#number): description` + a Glossary section in the body.
6. **Wait for Rex** — the Code Reviewer agent auto-runs on every PR.
7. **Merge requires two markers** — Rex's approval + explicit per-PR CEO approval via `/approve-merge <pr>`. Plan-level "go" doesn't count.

For larger changes (new skills, rule changes, workflow redesigns), open a discussion or draft PRD first.

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built with real-world experience shipping software with Claude Code.

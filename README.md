# ApexStack

**Where projects get forged.**

A multi-project ops repo where your projects reference each other, learn from shared experience, and ship production-ready under a strict SDLC. Built for founders and technical leads running 2–5 products at once.

You don't *add* apexstack to a project — projects get forged *inside* it. One ops repo. Every product. Shared memory. Strict gates. Production-ready MVPs.

Claude Code is the default driver, but the rules, hooks, and templates are plain markdown and shell. Swap the AI. Keep the forge. No SaaS. No lock-in.

**Proven shipping** TypeScript + AWS Lambda backends, Next.js web apps, Chrome extensions, and native **Swift** macOS desktop apps. The stack is process and guardrails — not a language or framework lock-in.

Inspired by [gstacks.org](https://gstacks.org/) — but purpose-built for software teams running more than one product at a time.

## What's Inside

```
apexstack/
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
│   ├── sdlc.md            # Full software development lifecycle
│   ├── code-review.md     # Code review process and standards
│   └── deployment.md      # Deployment and release process
│
├── templates/             # Reusable document templates
│   ├── prd.md             # Product Requirements Document
│   ├── technical-design.md # Technical design document
│   ├── adr.md             # Architecture Decision Record
│   └── agdr.md            # Agent Decision Record (AI-specific)
│
├── .claude/               # Claude Code primitives (the runnable layer)
│   ├── settings.json      # Hook wiring (PreToolUse)
│   ├── hooks/             # Shell scripts: block git add -A, block main push, secrets scan, branch & PR validation, pre-push reminder
│   ├── rules/             # Modular rule files imported via @.claude/rules/* (AgDR triggers, code standards, git conventions, PR quality, workflow gates)
│   ├── agents/            # Sub-agents: Code Reviewer (Rex), Security Reviewer (Shield), Dependency Auditor (Guardian), PR Manager, Ticket Manager
│   └── skills/            # 13 slash commands: /decide, /code-review, /security-review, /audit-deps, /write-spec, /idea, /handover, /projects, /inbox, /status, /tasks, /roadmap, /stakeholder-update
│
├── workspace/             # Live local clones of managed projects — gitignored
├── projects/              # Per-project committed docs (README, roadmap, AgDRs, updates)
├── apexstack.projects.yaml.example  # Portfolio registry template
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

ApexStack governs a **portfolio of repos** as one organisation. You fork apexstack, clone the fork, treat it as your "ops repo", and register every project you want under management. No `.apexstack/` symlinks, no nested installs — the fork IS the ops repo.

### 1. Star + Fork on GitHub

Visit [`github.com/me2resh/apexstack`](https://github.com/me2resh/apexstack), **Star** it, then **Fork** it into your org. You can keep the fork named `apexstack` or rename to something that fits your naming convention (`your-org/ops`, `your-org/apex`, etc.).

### 2. Clone your fork locally

```bash
gh repo clone your-org/apexstack
cd apexstack
```

Or with plain git:

```bash
git clone https://github.com/your-org/apexstack.git
cd apexstack
```

### 3. Add `upstream` for future updates

```bash
git remote add upstream https://github.com/me2resh/apexstack.git
```

Later, `git fetch upstream && git merge upstream/main` pulls the latest apexstack improvements into your fork.

### 4. Fill in `onboarding.yaml`

```bash
$EDITOR onboarding.yaml
```

Set company, team, tech stack, quality bar. Defaults are sensible — change what matters for your team.

### 5. Create the portfolio registry

```bash
cp apexstack.projects.yaml.example apexstack.projects.yaml
$EDITOR apexstack.projects.yaml   # list every repo you manage
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

## Why ApexStack?

**The problem**: Claude Code is powerful, but without structure it produces inconsistent results. Every team reinvents the same processes -- role definitions, review checklists, document templates, workflow gates.

**The solution**: ApexStack provides that structure as a reusable, open-source stack. One config file to customize, 20+ role definitions to use, battle-tested workflows to follow.

### What makes it different

| Feature | Without ApexStack | With ApexStack |
|---------|-------------------|----------------|
| Code reviews | Ad-hoc prompts | Structured checklist with role-based review |
| Technical decisions | Lost in chat history | Documented as Agent Decision Records |
| Quality gates | Hope and pray | Enforced workflow stages |
| Role consistency | Re-explain every session | Persistent role definitions |
| Onboarding | Days of context-setting | One config file |

## Roles

ApexStack includes 19 software development roles across 5 departments:

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

Each phase has entry criteria, activities, exit criteria, and quality gates.

### Code Review Process

Structured review with:

- Author responsibilities and PR description format
- Reviewer checklist (architecture, security, testing, performance)
- Feedback severity levels (blocking, suggestion, question)
- Response time targets

### Deployment Process

- Infrastructure as Code patterns
- CI/CD pipeline stages
- Environment promotion (staging -> production)
- Rollback procedures

## Templates

| Template | Purpose |
|----------|---------|
| PRD | Product Requirements Document with user stories, acceptance criteria |
| Technical Design | Architecture, domain model, API design, implementation plan |
| ADR | Architecture Decision Record for significant technical decisions |
| AgDR | Agent Decision Record -- AI-specific decision tracking |

## Customization

ApexStack is designed to be customized. Every role, workflow, and template can be modified to fit your team:

1. **Add roles**: Create new `.md` files in `roles/your-department/`
2. **Modify workflows**: Edit files in `workflows/`
3. **Add templates**: Drop new templates in `templates/`
4. **Override anything**: The stack is just markdown files -- edit freely

## Contributing

Contributions are welcome. Please:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request with a clear description

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built with real-world experience shipping software with Claude Code.

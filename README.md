# ApexStack

**Where projects get forged.**

A multi-project ops repo where your projects reference each other, learn from shared experience, and ship production-ready under a strict SDLC. Built for founders and technical leads running 2–5 products at once.

You don't *add* apexstack to a project — projects get forged *inside* it. One ops repo. Every product. Shared memory. Strict gates. Production-ready MVPs.

Claude Code is the default driver, but the rules, hooks, and templates are plain markdown and shell. Swap the AI. Keep the forge. No SaaS. No lock-in.

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
├── workspace/             # Live local clones (multi-project mode) — gitignored
├── projects/              # Per-project committed docs (multi-project mode)
├── apexstack.projects.yaml.example  # Portfolio registry template
│
├── golden-paths/          # Reusable infra & ops templates
│   └── pipelines/         # Drop-in GitHub Actions workflows (CI, code quality, security, dependency audit, PR title check, review check, SEO check)
│
├── docs/                  # Documentation
│   ├── getting-started.md # Setup guide
│   └── multi-project.md   # Full guide to multi-project mode
│
└── site/                  # Landing page
    └── index.html
```

## Operating modes

ApexStack supports two modes, set in `onboarding.yaml`:

| Mode | Default? | Use when |
|------|:---:|------|
| **`multi-project`** | ✅ default | You manage two or more repos as one organisation. ApexStack lives in an "ops repo" with a portfolio registry (`apexstack.projects.yaml`). Skills like `/projects`, `/inbox`, `/status`, `/tasks` aggregate across the registry. |
| `single-project` | opt-in | You manage exactly one repo and don't see that changing. ApexStack lives inside that one repo. The same skills scope to the current repo. |

Full guide: [`docs/multi-project.md`](docs/multi-project.md).

## Quick Start (multi-project — the default)

### 1. Clone ApexStack into your ops repo

The "ops repo" is the repo where you'll run Claude Code from to manage your portfolio. Common choices: a dedicated `your-org/ops` repo, or an existing internal-tools / playbook repo.

```bash
# from your ops repo
git clone https://github.com/me2resh/apexstack.git .apexstack
```

### 2. Symlink the runnable layer

Claude Code only looks for hooks, agents, skills, and `settings.json` at `.claude/`. Symlink so apexstack updates stay in sync:

```bash
# in your ops repo root
ln -s .apexstack/.claude .claude
```

### 3. Configure

Edit `.apexstack/onboarding.yaml`:

```yaml
apexstack:
  mode: multi-project   # default — leave as is

company:
  name: "Your Company"
  mission: "What you're building and why"

team:
  - name: "Alice"
    role: "tech-lead"
```

### 4. List your projects

```bash
# in your ops repo root
cp .apexstack/apexstack.projects.yaml.example apexstack.projects.yaml
$EDITOR apexstack.projects.yaml   # list every repo you manage
```

### 5. Wire CLAUDE.md

In your ops repo's `CLAUDE.md`:

```markdown
# Development Stack
@.apexstack/CLAUDE.md
```

### 6. Start working

```
/projects          # list every managed project + status
/inbox             # PRs, issues, comments needing your attention
/status            # git + CI snapshot per project
/decide            # make a technical decision (creates an AgDR)
```

The hooks fire on every `git` / `gh` command, the cross-project skills aggregate across the registry, and the Code Reviewer agent can be invoked with `/code-review <pr>`.

---

### Single-project install (opt-out)

If you only have one repo, install directly into it instead of an ops repo:

```bash
# in your one project repo
git clone https://github.com/me2resh/apexstack.git .apexstack
ln -s .apexstack/.claude .claude
$EDITOR .apexstack/onboarding.yaml   # set apexstack.mode: single-project
echo "@.apexstack/CLAUDE.md" >> CLAUDE.md
```

Skip step 4 entirely — there's no registry. The same skills scope to the current repo. Roadmap lives at `ROADMAP.md`, ideas at `IDEAS.md`. See [`docs/multi-project.md`](docs/multi-project.md) for the full comparison.

### Global install (alternative)

If you run **several** ops repos (a founder with a couple of orgs, a consultant with multiple clients), clone apexstack **once** globally and reference it from every ops repo instead of cloning into each. One place to upgrade, one place to patch.

```bash
# one time, globally
git clone https://github.com/me2resh/apexstack.git ~/.apexstack

# in each ops repo (replaces steps 1 and 2 of the default flow)
ln -s ~/.apexstack/.claude .claude
echo '@~/.apexstack/CLAUDE.md' >> CLAUDE.md

# steps 3, 4, 5, 6 are the same as the default flow
```

**Tradeoff**: the symlinks point at an absolute path in your home directory, so moving `~/.apexstack/` breaks the link. Not a good fit if you sync dotfiles across machines with different home paths.

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

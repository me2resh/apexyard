# ApexYard

**Where projects get forged.**

A multi-project ops repo where your projects reference each other, learn from shared experience, and ship production-ready under a strict SDLC. Built for founders who ship alone, or companies standing up AI-enabled squads.

You don't *add* apexyard to a project — projects get forged *inside* it. One ops repo. Every product. Shared memory. Strict gates. Production-ready MVPs.

OpenCode and the OpenAI Codex CLI are the default drivers, but the rules, hooks, and templates are plain markdown and shell. Swap the AI. Keep the forge. No SaaS. No lock-in.

The repo's source of truth lives in `shared/` (provider-agnostic YAML + TypeScript). A single `bun run bin/sync.ts` regenerates both `.opencode/` (OpenCode config) and `.codex/` (Codex CLI config) from that one tree. Default model is `opencode/minimax-m3-free`; review / security / architecture agents upgrade to `openai/gpt-5.5` via `shared/config/defaults.json → tiered_agents`.

**Proven shipping** TypeScript + AWS Lambda backends, Next.js web apps, Chrome extensions, and native **Swift** macOS desktop apps. The stack is process and guardrails — not a language or framework lock-in.

## What's Inside

```
apexyard/
├── INSTRUCTIONS.md         # Stack entry point — read by OpenCode + Codex
├── CLAUDE.md               # Legacy Claude Code entry point (kept for adopters)
├── onboarding.yaml         # Your company config — fill this in to adopt the stack
│
├── shared/                 # Single source of truth (canonical, AI-agnostic)
│   ├── config/             # Default provider / permission / gate config
│   ├── roles/              # 23 role YAMLs across engineering / product / design / security / data
│   ├── skills/             # 55 skill YAMLs
│   ├── hooks/              # 36 hook TS wrappers (shell out to .claude/hooks/*.sh)
│   └── rules/              # 11 rule markdown files
│
├── bin/                    # Generator scripts (Bun + TypeScript)
│   ├── sync.ts             # shared/ → .opencode/ + .codex/
│   └── migrate-from-claude.ts   # .claude/ → shared/ (one-shot, idempotent)
│
├── .opencode/              # Generated OpenCode config (do not edit)
│   ├── opencode.json       # Main config (providers, default model, agents)
│   ├── agent/              # 23 role markdown files
│   ├── skill/              # 55 skill folders with SKILL.md
│   ├── plugins/
│   │   └── apexyard-hooks.ts   # Composed plugin (1 file, 36 hooks)
│   └── instructions/       # 4 rule files + INDEX.md
│
├── .codex/                 # Generated Codex CLI config (do not edit)
│   ├── config.toml         # Model + sandbox + inline [[hooks.<Event>]] blocks + [agents] map
│   ├── AGENTS.md           # Project-level Codex instructions
│   ├── agents/             # 23 subagent TOML files (model + sandbox + instructions)
│   └── hooks/              # 36 bash wrappers invoking `bun run shared/hooks/<name>.ts`
│
├── .claude/                # Original Claude Code primitives (source of truth for bash logic)
│   ├── settings.json       # Claude Code hook wiring (kept for fallback)
│   ├── hooks/              # 36 bash scripts — the actual gate logic
│   ├── rules/              # 11 rule files
│   ├── agents/             # 23 agent markdown files
│   └── skills/             # 55 skill folders
│
├── workspace/              # Live local clones of managed projects — gitignored
├── projects/               # Per-project committed docs (README, roadmap, AgDRs, updates)
├── apexyard.projects.yaml.example  # Portfolio registry template
│
├── golden-paths/           # Reusable infra & ops templates
│   └── pipelines/          # Drop-in GitHub Actions workflows
│
├── docs/                   # Documentation
│   ├── getting-started.md  # Setup guide
│   └── multi-project.md    # Full setup guide (fork flow, directory layout, daily workflow, FAQ)
│
└── site/                   # Landing page (deployed to yard.apexscript.com)
    ├── index.html
    ├── architecture.html
    ├── skills.html
    ├── robots.txt         # Crawler directives + sitemap pointer
    ├── sitemap.xml        # XML sitemap for search engines
    ├── llms.txt           # llmstxt.org manifest — AI/LLM crawler index
    ├── llms-full.txt      # Full-content concatenation for one-shot LLM consumption
    ├── skill.md           # Capability manifest for AI coding agents (upstream GEO/AEO convention)
    └── og/                # Open Graph share-preview PNGs
```

> **For AI coding agents:** the repo root carries `AGENTS.md` — universal entry doc for Cursor / Claude Code / Aider / Cline. `site/skill.md` (lowercase, distinct from `.claude/skills/<name>/SKILL.md`) is the capability manifest for AI agents asking "should I recommend ApexYard for this user's task?".

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

## Harnesses — pick your CLI

Apexyard ships side-by-side wiring for two agent CLIs. Same workflow gates, same 23 roles, same 55 skills, same 36 hooks — just a different runtime. Pick one per session.

| Harness | Default model | Cost | Free tier | Hook mechanism | Where to look |
|---|---|---|---|---|---|
| **OpenCode** | `opencode/minimax-m3-free` | Free | Yes | TS plugin in `.opencode/plugins/` | `.opencode/opencode.json` |
| **Codex CLI** | `gpt-5.5` | Paid | No | Inline `[[hooks.*]]` in TOML | `.codex/config.toml` + `.codex/agents/*.toml` |

The same 36 bash scripts in `.claude/hooks/*.sh` are the source of truth on both sides — the TS wrappers in `shared/hooks/*.ts` shell out to them.

```bash
# OpenCode
opencode                   # plugin auto-loads; default model is free tier

# Codex CLI
codex                      # needs OPENAI_API_KEY; project must be trusted on first run
codex doctor               # validate config + hooks loaded
```

Run `bun run bin/sync.ts` to regenerate both `.opencode/` and `.codex/` from `shared/`. The generator is deterministic — re-running it produces 0 changes.

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

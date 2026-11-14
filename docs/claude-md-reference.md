# CLAUDE.md Reference Tables

This page holds the reference tables that `CLAUDE.md` does not load at session start.
Read this page when a task needs one of the tables.

`CLAUDE.md` keeps only the text that agents use on almost every turn.
That text is the role model, role activation, the rule index, the always-on floor, and the pointers to the gate table and the git conventions.
Issue me2resh/apexyard#2035 moved the tables below to this page to make the session-start context smaller.

## Claude Code integration

ApexYard ships a `.claude/` directory.
The directory holds the Claude Code parts that make the markdown process into a workflow that runs.

| Layer | Path | Purpose |
|-------|------|---------|
| Hooks | `.claude/hooks/` | Shell scripts that enforce SDLC rules. They enforce ticket-first edits, ORBIT slices, migrations, automatic code review, merge gates, and red-CI blocks. They also check commit format, AgDRs, branch and PR titles, secrets, onboarding config, upstream drift, leak protection, skill intent, and review markers. Bootstrap skills are exempt from the ticket-first gate. |
| Rules | `.claude/rules/` | 23 modular rule files. Planning and process: AgDR triggers, plan mode, loop mode, parallel work, right-size ceremony, reconcile before build, workflow gates. Agents and roles: agent role selection, role triggers, skill first, isolated builds, build-handbook discovery. Git and PRs: git conventions, PR quality, PR workflow, external-write retry, leak protection, ticket vocabulary. Writing and reporting: writing standard, reporting style, evidence grounding, glossary lookup, code standards. |
| Handbooks | `handbooks/` | Coding standards that the adopter writes. Rex reads them during code review. `architecture/` and `general/` always load. `language/<lang>/` loads when the diff matches. Handbooks are advisory unless they carry the `ENFORCEMENT: blocking` marker. See [`handbooks/README.md`](../handbooks/README.md). |
| Agents | `.claude/agents/` | 23 sub-agents: 4 utility agents (Rex, Hakim, Munir, Naqid), 7 engineering, 1 architecture (Tariq), 6 product and design, and 5 security and data. See AgDR-0050, AgDR-0054, AgDR-0078, and AgDR-0105. |
| Skills | `.claude/skills/` | Slash commands. The full list follows. |
| Settings | `.claude/settings.json` | Connects the hooks to the Claude Code hook events: `PreToolUse`, `PostToolUse`, `SessionStart`, `UserPromptSubmit`, and `ConfigChange`. |

Claude Code finds the hooks, agents, and skills automatically when this directory is at the project root.
The per-clone `claudeMdExcludes` setting in `.claude/settings.local.json` keeps the rule bodies out of auto-load.
`CLAUDE.md` names each rule file. An agent reads a rule file when the work needs it.

See `docs/getting-started.md` for the integration model and for how to install the `.claude/` layer.

### Available skills (72)

Each row gives one line for a skill. The full text for each skill is in `.claude/skills/<name>/SKILL.md`.
The count includes 3 deprecated aliases: `/spike-close`, `/prototype-close`, and `/tickets-batch` (me2resh/apexyard#2028).
Each alias passes its arguments to the new mode. The aliases ship deprecated in v5.11.0, and v5.12.0 removes them. A `Skill(<alias>)` permission now needs `Skill(spike)`, `Skill(prototype)`, or `Skill(task)`.

| Skill | Purpose |
|-------|---------|
| `/preflight` | Read-only environment checks before setup. Also available as `apexyard doctor`. |
| `/setup` | First-run bootstrap. Configures `onboarding.yaml` in 3 exchanges. |
| `/launch-check` | Quick 10-dimension go/no-go check at milestones. On WARN or FAIL, it names and offers the matching full audit. `--workflow` runs in parallel. |
| `/threat-model` | STRIDE threat model: spoofing, tampering, repudiation, disclosure, DoS, and EoP. |
| `/accessibility-audit` | WCAG 2.1 AA accessibility audit: perceivable, operable, understandable, robust. |
| `/compliance-check` | GDPR and ePrivacy compliance: consent, privacy policy, data handling, and user rights. |
| `/analytics-audit` | Analytics event-taxonomy audit: SDK coverage, naming, and funnel completeness. |
| `/seo-audit` | Technical SEO audit: meta tags, sitemap, robots.txt, OG, and structured data. |
| `/geo-audit` | GEO and AEO audit: `llms.txt`, `AGENTS.md`, AI-crawler robots, and JSON-LD citation grounding. |
| `/performance-audit` | Performance audit: bundle size, images, lazy load, code split, and Core Web Vitals. |
| `/monitoring-audit` | Observability audit: error tracking, health endpoints, alerting, and runbooks. |
| `/docs-audit` | Diataxis docs audit: tutorials, how-to guides, reference, and explanation. |
| `/mutation-test` | Mutation-testing sensor for Stryker, MutPy, go-mutesting, and mutant. Runs at milestones. Exits 3 when no tool is available. |
| `/eval-agents` | Scores a review agent (Rex, Hakim, or Tariq) against a labeled PR corpus. The headline metric is approve-precision. |
| `/start-ticket` | Declares the active ticket for this session. Code edits need it. |
| `/approve-merge` | Records per-PR CEO approval and merges. The merge gate needs it. |
| `/explain-pr` | Read-only PR walkthrough: what, why, risks, and decisions. Optional comprehension quiz. Never writes markers or merges. |
| `/pr-status` | Read-only PR gate state: approval records, forge checks and rules, QA evidence, and the next missing action. Never writes markers or merges. |
| `/approve-design` | Records per-PR design-review approval for UI PRs. The design gate needs it. |
| `/decide` | Makes a technical decision and creates an Agent Decision Record (AgDR). |
| `/agdr` | Browses, searches, shows, and counts the AgDRs across the portfolio. |
| `/drive-to-green` | Drives one PR through CI, review, fixes, and delta review. Stops before human approval. |
| `/code-review` | Starts the Code Reviewer agent (Rex) on a PR. |
| `/security-review` | Starts the Security Reviewer agent (Hakim) on a PR. |
| `/design-review` | Starts the Solution Architect agent (Tariq) on a technical design, migration AgDR, or feature spec. |
| `/design-sync` | Syncs a local component library to a claude.ai/design design-system project, one change at a time. |
| `/challenge` | Starts The Contrarian (Naqid) to steelman and then challenge an idea, feature, or decision. Advisory only. Never blocks a gate. |
| `/approve-architecture` | Records per-PR architecture-review approval for design-artifact PRs. The architecture gate needs it. |
| `/audit-deps` | Audits dependencies for vulnerabilities, outdated packages, and licences. |
| `/write-spec` | Writes a PRD or feature spec from a problem statement. |
| `/validate-idea` | Short 5-question check before `/write-spec`. |
| `/plan-initiative` | Initiative to milestones to tasks: interview, DAG, sorted sequence, and filing with `blocks` and `blocked by` cross-references. |
| `/feature` | Creates a structured feature ticket with a user story and acceptance criteria. |
| `/bug` | Creates a structured bug ticket with Given/When/Then, repro steps, and severity. |
| `/report-apexyard-bug` | Reports a bug in the apexyard framework itself to `me2resh/apexyard`, with leak scrubbing. Different from `/bug`. |
| `/request-apexyard-feature` | Requests a feature for the apexyard framework itself from `me2resh/apexyard`. Different from `/feature`. |
| `/task` | Creates a structured technical task ticket. `--batch` files 2 to 20 mixed tickets in one shared-context flow. |
| `/tickets-batch` | Deprecated alias for `/task --batch`. |
| `/migration` | Creates a labelled migration ticket and a migration AgDR. The migration gate needs them. |
| `/spike` | Creates a time-boxed spike ticket. `--close --promote` files a feature; `--close --discard` writes a memo. Exempt from the AgDR and coverage gates. |
| `/scaffold` | Interviews the owner and generates the project floor from a validated scaffold spec. |
| `/spike-close` | Deprecated alias for `/spike --close`. |
| `/prototype` | Creates a throwaway UX or demo prototype ticket. `--close --promote` or `--close --discard` records the disposition. Same exemptions as `/spike`. |
| `/prototype-close` | Deprecated alias for `/prototype --close`. |
| `/walking-skeleton` | Creates a feature ticket for the thinnest end-to-end slice through every layer. The team keeps and grows it. Full SDLC. |
| `/codify-rule` | Turns a review comment that caught a Rex miss into a draft handbook entry. |
| `/investigation` | Creates an investigation ticket and a live document for long root-cause work. |
| `/idea` | Captures a new product idea in the shared backlog. |
| `/handover` | Onboards an external repo. Scores harnessability across 5 dimensions, picks the docs to generate, and offers to file Next Steps as tickets. |
| `/onboard` | Guided first-run onboarding: capability tour, handover or new project, and a guided first win. |
| `/tutorial` | Replays the capability tour and the full glossary at any time. Respects the depth mode. |
| `/extract-features` | Six-axis feature inventory for rewrites: routes, models, jobs, tests, UI, and docs. |
| `/feature-diagram` | Mermaid flowchart for one feature: the routes, models, jobs, and screens that it uses. |
| `/process` | Extracts a business process from registered repos and writes lint-clean BPMN 2.0. |
| `/c4` | Generates C4 L1 and L2 Mermaid diagrams from the codebase of a project. |
| `/dfd` | Extracts a Data Flow Diagram with trust boundaries, as Mermaid and optional Threat Dragon JSON. |
| `/tech-vision` | Interactive author for the architecture vision template: target, gap, migration, and anti-scope. |
| `/journey` | One self-contained user-journey HTML page with boxes, arrows, and a modal for each page. |
| `/pdf` | Converts markdown, HTML, or BPMN to PDF. Asks for the destination. |
| `/debug` | Structured debugging with hypotheses for issues that resisted the first fixes. |
| `/update` | Syncs the ops fork with upstream apexyard: preview, merge or rebase, and sync branch. |
| `/orbit` | Runs the opt-in ORBIT planning lifecycle for one managed project. ApexYard governance stays in place. |
| `/split-portfolio` | Moves a single-fork adopter to split-portfolio mode: public framework and private portfolio. |
| `/release` | Framework only. Cuts an apexyard release: diff, version bump, CHANGELOG, release PR, and tag. |
| `/release-sync` | Framework only. Syncs `main` back to `dev` after a squash-merge release. This stops repeated merge conflicts. |
| `/projects` | Lists all managed projects from the registry with their status. |
| `/inbox` | Items that need your attention: PRs, issues, comments, blockers, and stale-ticket flags. |
| `/status` | Current snapshot: git, CI, and work in progress. Use `--briefing` for the 4-line form. |
| `/tasks` | Task list across the portfolio, with direct URLs, in priority order. |
| `/roadmap` | Updates or creates the product roadmap. |
| `/stakeholder-update` | Generates weekly, monthly, or launch stakeholder updates. |
| `/fan-out` | Starts N parallel agents in one message, with an agent type for each task and worktree isolation. |

## Templates

| Template | When to use | Path |
|----------|-------------|------|
| PRD | Define a new feature or product | `templates/prd.md` |
| Technical Design | Plan the implementation | `templates/technical-design.md` |
| ADR | Record an architecture decision | `templates/adr.md` |
| AgDR | Record an AI agent decision | `templates/agdr.md` |
| Migration AgDR | Record a migration decision: rollback, downtime, consumers, and observability | `templates/agdr-migration.md` |
| Investigation | Long root-cause work: incident retros, bug history, regressions, and performance problems. Uses a hypothesis tree and a live document. `/investigation` uses it. | `templates/tickets/investigation.md` |
| C4 Context (L1) | The system and its external actors, one for each project | `templates/architecture/c4-context.md` |
| C4 Container (L2) | The deployable units inside the system | `templates/architecture/c4-container.md` |
| Architecture Vision | Target-state architecture, a migration path over several quarters, and explicit anti-scope. Write it with `/tech-vision <project>`. | `templates/architecture/vision.md` |
| Data Flow Diagram (DFD) | Trust boundaries and data crossings. The STRIDE threat model uses it. | `templates/architecture/dfd.md` |
| Sequence Diagram | A request flow in time order, for example an auth handshake or a payment flow | `templates/architecture/sequence.md` |

## CI/CD pipelines

Reusable GitHub Actions workflows are in `golden-paths/pipelines/`.

| Pipeline | Purpose |
|----------|---------|
| `ci.yml` | Combined pipeline: code quality, security, and dependencies |
| `code-quality.yml` | TypeScript, ESLint, tests, and build |
| `swift-ci.yml` | Swift Package Manager build and guarded test on macOS |
| `security.yml` | Semgrep SAST, npm audit, and secrets detection |
| `dependency-audit.yml` | Weekly vulnerability and licence scan |
| `pr-title-check.yml` | Requires a ticket ID in the PR title |
| `review-check.yml` | Blocks the merge when the Code Reviewer has not reviewed the latest commit |
| `seo-check.yml` | SEO analysis for content files |

Copy the pipelines that you need into the `.github/workflows/` directory of your project.
See `golden-paths/pipelines/README.md` for the full details.

## Quick reference

| What | Where |
|------|-------|
| Company config | `onboarding.yaml` |
| **Portfolio registry** | `apexyard.projects.yaml` |
| Role definitions | `roles/` |
| Workflows | `workflows/` |
| Templates | `templates/` |
| Hooks | `.claude/hooks/` |
| Rules (modular, framework-wide) | `.claude/rules/` |
| **Adopter handbooks** (Rex reads them during code review) | `handbooks/`. See [`handbooks/README.md`](../handbooks/README.md) for discovery and for advisory and blocking handbooks. |
| Agents | `.claude/agents/` |
| Skills (slash commands) | `.claude/skills/` |
| Hook wiring | `.claude/settings.json` |
| **Per-project docs** | `projects/<name>/` |
| **Live working copies** (gitignored) | `workspace/<name>/` |
| **Cognitive memory layer** (optional, docs only) | `.claude/memory/`. See [`.claude/memory/README.md`](../.claude/memory/README.md) for what it is and how it differs from AgDRs and Claude Code session memory. |
| **Topology bundles** (harness templates for each service shape) | `topologies/<name>/`. See [`topologies/README.md`](../topologies/README.md). |
| CI pipelines | `golden-paths/pipelines/` |
| Getting started | `docs/getting-started.md` |
| Full setup guide | `docs/multi-project.md` |
| Rule audit (each MUST and its hook, advisory, or deferred status) | `docs/rule-audit.md` |
| LSP-aware navigation (optional) | Set `ENABLE_LSP_TOOL=1` and install the plugin for each language. See `docs/getting-started.md` § "Optional: LSP-aware code navigation". |

In split-portfolio mode, `onboarding.yaml`, `apexyard.projects.yaml`, `projects/`, and `workspace/` are in the sibling portfolio repo.
Resolve them with `.claude/hooks/_lib-portfolio-paths.sh`.

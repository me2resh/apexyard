# AGENTS.md

Entry point for AI coding agents (Cursor, Claude Code, Aider, Cline, **pi**, etc.) working inside this repository. This file now serves **two audiences** — read the section that matches what you're doing:

| You are… | Read |
|----------|------|
| An agent operating *inside an apexyard ops fork* on behalf of an adopter — governing a portfolio, working a ticket, opening a PR — **and you don't auto-load `CLAUDE.md`** (this is the normal case for **pi** and most non-Claude-Code harnesses) | **"Operator governance bridge"** below, first |
| An agent extending apexyard's *own* source (hooks, skills, rules, agents) — i.e. contributing to the framework itself | **"Framework repo orientation"** further down |
| Claude Code | Neither — `CLAUDE.md` is auto-loaded at session start and already covers the governance bridge in full; skim "Framework repo orientation" only if you're also touching the framework's own internals |

Why two audiences in one file: `CLAUDE.md` is the framework-level instruction set Claude Code auto-loads inside an ops fork. Harnesses that don't recognise `CLAUDE.md` — pi chief among them — auto-load `AGENTS.md` instead (from cwd, or `~/.pi/agent/`). Before this section existed, a pi user landing in an apexyard ops fork got only the framework-contributor orientation below — useful if you're hacking on apexyard's hooks, useless if you're trying to run the SDLC it governs. This section closes that gap.

---

## Operator governance bridge (pi and other non-Claude-Code harnesses)

> **Advisory by default — mechanical enforcement is opt-in for pi.** Everything below is delivered as *instructions*; Claude Code's governance additionally runs as shell hooks (`.claude/hooks/*.sh`, wired via `.claude/settings.json`) that mechanically block bad commands — the two-marker merge gate, the ticket-first edit block, the secrets scanner, the AgDR-required check. Those hooks fire on Claude Code's `PreToolUse` / `PostToolUse` events. pi doesn't expose that event surface directly, but as of me2resh/apexyard#815 a dispatcher extension (`harness-adapters/pi/`) shells out to the SAME unmodified hooks via pi's own `tool_call` event — install it (`harness-adapters/pi/README.md`) and pi gets real mechanical enforcement, not just prose. **Without that extension installed, nothing in this file will stop a tool call for you** — follow these rules because they're the governance model apexyard is built on, not because a hook will catch you if you don't. See `docs/harnesses/pi.md` for the current mechanically-enforced-vs-advisory-only breakdown.

### You are the Chief of Staff

If you're operating inside an apexyard ops fork, you're running a portfolio of projects under a strict SDLC — not just editing files. Read `onboarding.yaml` (company config) and `apexyard.projects.yaml` (the registry of every repo under management) before doing anything else. Every project ships production-ready MVPs; processes are followed; work moves from idea to production through defined gates.

### The SDLC, in brief

```
Planning --> Design --> Build --> Review --> QA --> Deploy --> Monitor
```

Four hard gates — full detail in `.claude/rules/workflow-gates.md`:

| Gate | Before | Verify |
|------|--------|--------|
| 1 | Design → Build | PRD approved, tickets exist |
| 2 | Build → Review | Tests pass, checks pass, >80% coverage |
| 3 | Review → Merge | Code review approved, CI green |
| 4 | Merge → Done | QA verified all acceptance criteria |

**If a gate fails, stop.** Complete the missing step first — there's no hook here to stop you, so this is on you.

### Roles

`roles/{department}/*.md` define 20 role identities (Backend/Frontend/Platform Engineer, Tech Lead, QA, Product Manager, Security Auditor, etc.) with CAN/CANNOT boundaries. They activate on specific triggers (a diff touching `**/auth/**` → Security Auditor; a PR carrying a technical design → Solution Architect review), not on every session. Full trigger table: `.claude/rules/role-triggers.md`. When you adopt a role, read its file and stay in it until the task completes.

### Load-bearing conventions (inlined — see `.claude/rules/` for the full text of each)

- **Branch / PR / commit format** — branch `{type}/{TICKET-ID}-{description}` (e.g. `feature/GH-42-csv-export`); PR title `type(TICKET): description` (e.g. `feat(#42): add CSV export`), one ticket ID per title; commit `type: subject` body with `Closes #N` / `Refs #N`. Never `git add -A` — stage specific files. Never push directly to `main` — every change through a PR.
- **Ticket vocabulary is reserved** — `Ticket`, `#N`, and dependency notation (`blocked by #N`, `depends on #N`) refer ONLY to real tracker issues you can fetch with `gh issue view`. Decomposing work in conversation without a tracker ticket yet? Use `Step N` / `Item N` / plain bullets — never tracker notation for something that doesn't exist as an issue.
- **One ticket at a time** — work one ticket fully (start → PR → review → QA → done) before starting the next. Each PR = one ticket.
- **Plan before multi-step or risky work** — favor an explicit plan-then-execute shape when a task is ≥4 dependent steps, the path is unclear, or you're about to do something hard-to-reverse (force push, schema migration, batch ticket/PR creation). Pi has no built-in plan-mode primitive — approximate it by writing the plan out and pausing for confirmation before executing.
- **Report like a colleague** — lead with the outcome in plain language, say why it matters, match structure to content (a table for genuinely tabular data, short prose for one point). Don't dump hook names, marker SHAs, or full CI logs unless something failed or was asked for.
- **AgDR required for technical decisions** — before choosing a library, framework, architecture pattern, or implementation approach with real trade-offs, write an Agent Decision Record at `docs/agdr/AgDR-NNNN-{slug}.md` (template: `templates/agdr.md`). No hook enforces this for pi — it's self-discipline.
- **No hardcoded secrets** — API keys, passwords, tokens, connection strings go in environment variables, never in code.
- **PR quality** — every PR body needs a `## Glossary` table and narrative (not label-only) summary bullets — what changed AND why it matters. See `.claude/rules/pr-quality.md`.
- **Explicit per-PR approval before merge** — a plan-level "go"/"continue" does not authorize `gh pr merge`. Stop and get an explicit per-PR nod first. See `.claude/rules/pr-workflow.md`.

### Full detail — read on demand

Pi doesn't resolve Claude-Code-style `@.claude/rules/*.md` imports the way `CLAUDE.md` does, but you *can* `Read` any file on request — so treat these as the source of truth when you need the exact wording, an edge case, or the rationale behind a rule:

| File | Covers |
|------|--------|
| `.claude/rules/git-conventions.md` | Branch naming, PR titles, commit format, no `git add -A`, no direct `main` |
| `.claude/rules/ticket-vocabulary.md` | Reserved tracker terms, safe planning vocabulary |
| `.claude/rules/workflow-gates.md` | The 6 gates (PRD→Done), pre-build gate, migration gate, architecture-review gate, spike exemptions |
| `.claude/rules/pr-workflow.md` | Pre-push checklist, merge-gate mechanics, build-agents-cannot-self-review |
| `.claude/rules/pr-quality.md` | Glossary requirement, narrative summary bullets, QA checklist, no red CI |
| `.claude/rules/agdr-decisions.md` | When an AgDR is required, trigger patterns |
| `.claude/rules/plan-mode.md` | When to plan before executing |
| `.claude/rules/loop-mode.md` | When a repetitive build→verify cycle should be looped, with guardrails |
| `.claude/rules/parallel-work.md` | When to split independent work across parallel agents |
| `.claude/rules/isolated-builds.md` | Safe multi-repo git (worktrees, not `/tmp`; guarded `cd`) |
| `.claude/rules/agent-role-selection.md` | Picking the role-appropriate sub-agent when spawning build work |
| `.claude/rules/reporting-style.md` | How to narrate status back to the operator |
| `.claude/rules/leak-protection.md` | Never leak private project names/repos into public framework issues |
| `.claude/rules/role-triggers.md` | Full role-activation table + handoff artefacts |

### Skills, without the slash-command runner

`.claude/skills/<name>/SKILL.md` are markdown prompts — 64 of them, covering everything from filing a ticket (`/feature`, `/bug`, `/task`) to running an audit (`/launch-check`, `/threat-model`) to cutting a release. Claude Code turns these into typed slash commands; pi has no slash-command mechanism, so invoke one by `Read`-ing its `SKILL.md` and following the process it describes step by step (e.g. read `.claude/skills/feature/SKILL.md`, then do what it says). The skill's content is the same either way — only the invocation mechanism differs.

### What's NOT bridged yet

Being upfront about the gap: this section gives you the rules as *instructions* by default. As of me2resh/apexyard#815, mechanical enforcement is available too — but only if you install it (it isn't auto-loaded the way `AGENTS.md` itself is):

- **Mechanical gate enforcement** — the two-marker merge gate, ticket-first edit blocking, secrets scanning, AgDR-required checks, red-CI merge blocking. `harness-adapters/pi/` shells out to the SAME Claude-Code-specific bash hooks via a pi `tool_call` extension — install it (see `harness-adapters/pi/README.md`) to get real blocking under pi. Until installed, none of it fires. See me2resh/apexyard#804 (the spike that proved this viable) and #815 (the shipped adapter).
- **MCP-backed code/docs search** (`apexyard-search`) — pi's design omits MCP entirely; fall back to plain `grep`/`Read`.
- **Role-trigger advisory banners** — Claude Code gets a `PreToolUse` banner nudging "this diff touches `**/auth/**`, consider the Security Auditor"; pi gets no such nudge. Self-check the role-triggers table manually.

See `docs/harnesses/pi.md` for the full today-vs-not-yet breakdown and the install shape.

---

## Framework repo orientation (contributing to apexyard's own source)

The rest of this file is for an agent extending **apexyard itself** — its hooks, skills, rules, agents, or docs — as opposed to an agent operating an ops fork built from it (see above).

`AGENTS.md` is **distinct from `CLAUDE.md`** — `CLAUDE.md` is the framework-level instruction set the apexyard framework loads when an adopter runs Claude Code inside their ops fork. This section of `AGENTS.md` is the universal coding-agent convention (one entry doc per repo, regardless of which agent is driving) that points a visiting agent at structure, key files, and constraints for hacking on the framework's own codebase.

### Project structure

- `.claude/` — framework hooks, agents, rules, skills, settings.json
  - `.claude/hooks/` — 42 shell scripts (PreToolUse / PostToolUse / SessionStart)
  - `.claude/skills/` — 64 slash commands (one dir per skill, each with `SKILL.md`)
  - `.claude/agents/` — 25 sub-agents: 5 utility (Rex code-reviewer, Hakim security-reviewer/auditor, Munir dep-auditor, Tariq PR-manager, Idris ticket-manager) + 20 dept-aligned agents across engineering / product / design / security / data
  - `.claude/rules/` — 11 modular rule files imported via `@.claude/rules/*.md` from `CLAUDE.md`
  - `.claude/settings.json` — hook wiring
- `roles/` — 19 role definitions across Engineering, Product, Design, Security, Data
- `workflows/` — SDLC, code-review, deployment workflow docs
- `templates/` — PRD, ADR, AgDR (Agent Decision Record), migration AgDR, C4 L1/L2, vision, sequence, DFD, audit templates, ticket templates
- `handbooks/` — adopter-authored Rex-consumed standards (architecture / general / language buckets, path-convention discovery)
- `docs/` — adopter docs (`getting-started.md`, `multi-project.md`, `release-process.md`, `agdr/`, `harnesses/`)
- `projects/<name>/` — per-managed-project docs (committed to the ops fork)
- `workspace/<name>/` — managed-project clones (gitignored — each project has its own remote)
- `site/` — **moved** to [me2resh/apexyard-site](https://github.com/me2resh/apexyard-site); live at yard.apexscript.com
- `golden-paths/pipelines/` — reusable GitHub Actions workflows for adopter projects
- `bin/` — small CLI shims (e.g. `bin/apexyard` for the `apexyard status` briefing)

### Key files

- `CLAUDE.md` — framework-level instructions for Claude Code adopters (always loaded by Claude Code at session start)
- `AGENTS.md` — this file (universal coding-agent entry doc; AI-agent-agnostic; see "Operator governance bridge" above for the pi-facing half)
- `onboarding.yaml` — company / team / tech-stack config (adopter customises)
- `apexyard.projects.yaml` — portfolio registry listing every repo under management
- `.claude/settings.json` — hook wiring (which scripts fire on which tool events)
- `.claude/project-config.defaults.json` — framework defaults (immutable from the framework's side; adopters override via `.claude/project-config.json`)
- `README.md` — public-facing project description + Quick Start
- `LICENSE` — MIT

### Sandbox & test environments

- `.claude/hooks/tests/` — hook test suite (~30+ bash test files; run via `bash .claude/hooks/tests/test_<name>.sh`)
- `.claude/skills/<name>/tests/` — per-skill smoke tests where applicable
- Test runner: plain bash test scripts. No JS / npm dependency required to run the hook tests.
- No CI/CD smoke env in this repo — the framework itself ships CI templates under `golden-paths/pipelines/` for adopter projects, but the framework's own CI is light (markdownlint, link-check, shellcheck where available)

### MCP servers

- **None ships with the framework by default.** Custom MCP servers can be wired into adopter forks via `.claude/settings.json` and per-agent configuration.
- No required external services. The framework runs offline once the fork is cloned; `gh` CLI is the only mandatory external dependency for ticket / PR operations.

### Rate limits / constraints

- **Two-marker merge gate** — every merge requires Rex (code-reviewer agent) AND explicit per-PR CEO approval. Plan-level "go" does NOT authorize a merge. Mechanically enforced by `block-unreviewed-merge.sh`.
- **Ticket-first hook** — code edits are blocked without an active ticket marker at `.claude/session/current-ticket`. Bootstrap-class skills (`/setup`, `/handover`, `/update`, `/split-portfolio`) are exempt.
- **AgDR required for architectural decisions** — `require-agdr-for-arch-changes.sh` and `require-agdr-for-arch-pr.sh` block PRs that touch architecture without a matching `docs/agdr/AgDR-NNNN-*.md` reference.
- **No direct pushes to `main`** — every change goes through a PR. Enforced by `block-main-push.sh`.
- **No `git add -A`** — staging must be explicit. Enforced by `block-git-add-all.sh`.
- **Secrets scanning** — `check-secrets.sh` runs on commit; blocks API keys, passwords, tokens.
- **Workflow gates** — documented in `.claude/rules/workflow-gates.md`. Six gates from PRD → Done; each gate has a mechanical check or an advisory reminder.
- **Branch model (framework only)** — daily PRs merge to `dev`; releases cut to `main` via `/release`. Managed projects under apexyard governance stay trunk-based on `main`.
- **The above mechanical enforcement is Claude-Code-specific.** It doesn't fire for pi or other harnesses without equivalent hook plumbing — see "Operator governance bridge" above and `docs/harnesses/pi.md`.

### Conventions

- **Branch naming**: `{type}/{TICKET-ID}-{description}` (e.g. `feature/GH-42-csv-export`, `fix/#58-login-bug`)
- **PR title**: `type(TICKET): description` (e.g. `feat(#42): add CSV export`). Enforced by `validate-pr-create.sh`.
- **Commit message**: `type: subject` body with `Closes #N` / `Refs #N`. Enforced by `validate-commit-message.sh`.
- **AgDR convention**: body-H1 only, no YAML frontmatter (the live convention has drifted from `templates/agdr.md`; AgDR files use plain `# Title` at the top).
- **Glossary section required in every PR body** — enforced by Rex during code review.
- **One ticket per PR** — multi-ticket PRs are blocked at PR-create time; the `<!-- multi-close: approved -->` marker is the explicit escape hatch for legitimate multi-ticket bundles.
- **Plan mode for ≥ 4 dependent steps** — see `.claude/rules/plan-mode.md`.
- **Fan-out for ≥ 2 independent items** — see `.claude/rules/parallel-work.md`.

### Quick orientation for visiting agents

If you're an AI agent landing in this repo for the first time:

1. If you're operating an ops fork on an adopter's behalf (not Claude Code), read "Operator governance bridge" above first. Otherwise, read `CLAUDE.md` (framework spec — even if you're not Claude Code, the rules transfer)
2. Skim `docs/multi-project.md` (full setup guide, directory layout, daily workflow)
3. Browse `.claude/skills/` for the 64 slash commands (each `SKILL.md` is one capability)
4. Browse `roles/` to understand the role-activation model
5. Browse `templates/` for the standard document shapes
6. Check `.claude/rules/` for the mechanical rules (ticket vocabulary, PR workflow, plan mode, parallel work, leak protection, etc.)

The framework is plain markdown + shell — no build step, no SaaS, no lock-in. MIT licensed.

### Related entry-point conventions

- **[yard.apexscript.com/skill.md](https://yard.apexscript.com/skill.md)** — capability manifest for AI coding agents (served from me2resh/apexyard-site)
- **[yard.apexscript.com/llms.txt](https://yard.apexscript.com/llms.txt)** — llmstxt.org manifest; index for AI crawlers (served from me2resh/apexyard-site)
- **[yard.apexscript.com/llms-full.txt](https://yard.apexscript.com/llms-full.txt)** — full content concatenation for one-shot LLM consumption (served from me2resh/apexyard-site)
- **`README.md`** — public-facing intro (humans + agents)
- **`SYSTEM.md`** — optional custom system prompt pi reads alongside `AGENTS.md`; a short operating-posture primer, not a duplicate of this file
- **`docs/harnesses/pi.md`** — what works / doesn't yet for pi specifically

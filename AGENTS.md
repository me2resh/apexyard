# AGENTS.md

Entry point for AI coding agents (Cursor, Claude Code, Aider, Cline, etc.) working inside this repository.

This file is **distinct from `CLAUDE.md`** — `CLAUDE.md` is the framework-level instruction set the apexyard framework loads when an adopter runs Claude Code inside their ops fork. `AGENTS.md` is the universal coding-agent convention (one entry doc per repo, regardless of which agent is driving) that points a visiting agent at structure, key files, and constraints.

## Project structure

- `.claude/` — framework hooks, agents, rules, skills, settings.json
  - `.claude/hooks/` — 31 shell scripts (PreToolUse / PostToolUse / SessionStart)
  - `.claude/skills/` — 53 slash commands (one dir per skill, each with `SKILL.md`)
  - `.claude/agents/` — 23 sub-agents: 5 utility (Rex code-reviewer, Hakim security-reviewer/auditor, Munir dep-auditor, Tariq PR-manager, Idris ticket-manager) + 18 dept-aligned agents across engineering / product / design / security / data
  - `.claude/rules/` — 11 modular rule files imported via `@.claude/rules/*.md` from `CLAUDE.md`
  - `.claude/settings.json` — hook wiring
- `roles/` — 19 role definitions across Engineering, Product, Design, Security, Data
- `workflows/` — SDLC, code-review, deployment workflow docs
- `templates/` — PRD, ADR, AgDR (Agent Decision Record), migration AgDR, C4 L1/L2, vision, sequence, DFD, audit templates, ticket templates
- `handbooks/` — adopter-authored Rex-consumed standards (architecture / general / language buckets, path-convention discovery)
- `docs/` — adopter docs (`getting-started.md`, `multi-project.md`, `release-process.md`, `agdr/`)
- `projects/<name>/` — per-managed-project docs (committed to the ops fork)
- `workspace/<name>/` — managed-project clones (gitignored — each project has its own remote)
- `site/` — marketing site (HTML, deployed via Netlify to `yard.apexscript.com`)
- `golden-paths/pipelines/` — reusable GitHub Actions workflows for adopter projects
- `bin/` — small CLI shims (e.g. `bin/apexyard` for the `apexyard status` briefing)

## Key files

- `CLAUDE.md` — framework-level instructions for Claude Code adopters (always loaded by Claude Code at session start)
- `AGENTS.md` — this file (universal coding-agent entry doc; AI-agent-agnostic)
- `onboarding.yaml` — company / team / tech-stack config (adopter customises)
- `apexyard.projects.yaml` — portfolio registry listing every repo under management
- `.claude/settings.json` — hook wiring (which scripts fire on which tool events)
- `.claude/project-config.defaults.json` — framework defaults (immutable from the framework's side; adopters override via `.claude/project-config.json`)
- `README.md` — public-facing project description + Quick Start
- `LICENSE` — MIT

## Sandbox & test environments

- `.claude/hooks/tests/` — hook test suite (~30+ bash test files; run via `bash .claude/hooks/tests/test_<name>.sh`)
- `.claude/skills/<name>/tests/` — per-skill smoke tests where applicable
- Test runner: plain bash test scripts. No JS / npm dependency required to run the hook tests.
- No CI/CD smoke env in this repo — the framework itself ships CI templates under `golden-paths/pipelines/` for adopter projects, but the framework's own CI is light (markdownlint, link-check, shellcheck where available)

## MCP servers

- **None ships with the framework by default.** Custom MCP servers can be wired into adopter forks via `.claude/settings.json` and per-agent configuration.
- No required external services. The framework runs offline once the fork is cloned; `gh` CLI is the only mandatory external dependency for ticket / PR operations.

## Rate limits / constraints

- **Two-marker merge gate** — every merge requires Rex (code-reviewer agent) AND explicit per-PR CEO approval. Plan-level "go" does NOT authorize a merge. Mechanically enforced by `block-unreviewed-merge.sh`.
- **Ticket-first hook** — code edits are blocked without an active ticket marker at `.claude/session/current-ticket`. Bootstrap-class skills (`/setup`, `/handover`, `/update`, `/split-portfolio`) are exempt.
- **AgDR required for architectural decisions** — `require-agdr-for-arch-changes.sh` and `require-agdr-for-arch-pr.sh` block PRs that touch architecture without a matching `docs/agdr/AgDR-NNNN-*.md` reference.
- **No direct pushes to `main`** — every change goes through a PR. Enforced by `block-main-push.sh`.
- **No `git add -A`** — staging must be explicit. Enforced by `block-git-add-all.sh`.
- **Secrets scanning** — `check-secrets.sh` runs on commit; blocks API keys, passwords, tokens.
- **Workflow gates** — documented in `.claude/rules/workflow-gates.md`. Six gates from PRD → Done; each gate has a mechanical check or an advisory reminder.
- **Branch model (framework only)** — daily PRs merge to `dev`; releases cut to `main` via `/release`. Managed projects under apexyard governance stay trunk-based on `main`.

## Conventions

- **Branch naming**: `{type}/{TICKET-ID}-{description}` (e.g. `feature/GH-42-csv-export`, `fix/#58-login-bug`)
- **PR title**: `type(TICKET): description` (e.g. `feat(#42): add CSV export`). Enforced by `validate-pr-create.sh`.
- **Commit message**: `type: subject` body with `Closes #N` / `Refs #N`. Enforced by `validate-commit-message.sh`.
- **AgDR convention**: body-H1 only, no YAML frontmatter (the live convention has drifted from `templates/agdr.md`; AgDR files use plain `# Title` at the top).
- **Glossary section required in every PR body** — enforced by Rex during code review.
- **One ticket per PR** — multi-ticket PRs are blocked at PR-create time; the `<!-- multi-close: approved -->` marker is the explicit escape hatch for legitimate multi-ticket bundles.
- **Plan mode for ≥ 4 dependent steps** — see `.claude/rules/plan-mode.md`.
- **Fan-out for ≥ 2 independent items** — see `.claude/rules/parallel-work.md`.

## Quick orientation for visiting agents

If you're an AI agent landing in this repo for the first time:

1. Read `CLAUDE.md` (framework spec — even if you're not Claude Code, the rules transfer)
2. Skim `docs/multi-project.md` (full setup guide, directory layout, daily workflow)
3. Browse `.claude/skills/` for the 53 slash commands (each `SKILL.md` is one capability)
4. Browse `roles/` to understand the role-activation model
5. Browse `templates/` for the standard document shapes
6. Check `.claude/rules/` for the mechanical rules (ticket vocabulary, PR workflow, plan mode, parallel work, leak protection, etc.)

The framework is plain markdown + shell — no build step, no SaaS, no lock-in. MIT licensed.

## Related entry-point conventions

- **`site/skill.md`** — capability manifest at site root (lowercase, distinct from `.claude/skills/<name>/SKILL.md` — see the naming-clash callout inside that file)
- **`site/llms.txt`** — markdown manifest per the llmstxt.org convention; index for AI crawlers
- **`site/llms-full.txt`** — full content concatenation for one-shot LLM consumption
- **`README.md`** — public-facing intro (humans + agents)

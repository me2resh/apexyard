# apexyard — Canonical Instructions

> **For any agent operating inside an apexyard fork, this file is the primary entry point.** It is harness-agnostic: the same content is sliced and shipped to OpenCode (`.opencode/instructions/`) and Codex CLI (`.codex/AGENTS.md`) by `bin/sync.ts`.

## What is apexyard?

apexyard is a multi-project forge — a single ops repository that governs a portfolio of managed projects under one organisation. The repo you are in is your **ops repo**, a fork of `apexyard` cloned into your org. The registry file `apexyard.projects.yaml` at the ops-repo root lists every project under management.

## Setup (first run)

1. Read `onboarding.yaml` for company-specific configuration.
2. Read `apexyard.projects.yaml` — the portfolio registry.
3. Read `shared/config/defaults.json` — the canonical defaults for hooks, gates, and model tiers.
4. Run `bun run bin/sync.ts` to regenerate `.opencode/` and `.codex/` from `shared/`.

## Models

| Tier | Model | Use for |
|------|-------|---------|
| Default (free) | `opencode/minimax-m3-free` | Implementation, drafting, docs, simple edits |
| Critical (paid) | `openai/gpt-5.5` | Code review, security review, penetration testing, head-of-*, tech-lead |

Override per-agent via local gitignored `.opencode/opencode.json` or by editing `shared/config/defaults.json → tiered_agents`.

## Roles

19 role definitions live in `roles/`. Agent (executable) versions live in `shared/roles/` as YAML and are generated into `.opencode/agent/`. Activation is on signal — see `shared/rules/role-triggers.md`.

## Workflows

- **SDLC**: Planning → Design → Build → Review → QA → Deploy → Monitor. Gates in `shared/rules/workflow-gates.md`.
- **One ticket at a time.** Run `/start-ticket <N>` before any code edit.
- **Plan mode** for ≥4 dependent steps. **Fan-out** for ≥2 independent items.

## Code Standards

See `shared/rules/code-standards.md` for the full set. Highlights:

- Branch names: `{type}/{TICKET-ID}-{description}`
- PR titles: `type(TICKET): description`
- No direct pushes to `main` or `dev`
- Lint, typecheck, test, build must pass before push
- Code review required before merge
- Explicit per-PR approval required for every merge (mechanically enforced)

## Commands

| Skill | Purpose |
|-------|---------|
| `/setup` | First-run bootstrap |
| `/start-ticket <N>` | Declare active ticket |
| `/code-review <PR>` | Review a PR |
| `/decide <topic>` | Make a structured decision and create an AgDR |
| `/sync` | Regenerate `.opencode/` and `.codex/` from `shared/` |

## Hooks

The framework enforces 36 workflow gates. The same gate logic runs on **both** harnesses — see "Harnesses" below.

The most important gates (apply everywhere):

- **require-active-ticket** — blocks edits without an active ticket
- **block-main-push** — blocks `git push` to protected branches
- **validate-branch-name** — enforces `{type}/{TICKET-ID}-{description}` format
- **check-secrets** — scans staged changes for API keys, tokens, passwords
- **block-git-add-all** — blocks `git add -A` / `git add .`

## Harnesses

`apexyard` ships side-by-side wiring for two agent CLIs. Pick one per session; the workflow gates work identically on both.

### OpenCode (default, free tier available)

- Plugin: `.opencode/plugins/apexyard-hooks.ts` (composed of all 36 hook wrappers in `shared/hooks/*.ts`)
- Config: `.opencode/opencode.json`
- Default model: `opencode/minimax-m3-free` (configurable in `shared/config/defaults.json → default_model`)
- Start: `opencode` (loads plugin automatically from `.opencode/plugins/`)

### OpenAI Codex CLI (paid, all OpenAI models)

- Hooks: `.codex/hooks/<name>.sh` wrappers calling `bun run shared/hooks/<name>.ts`
- Config: `.codex/config.toml` (model + sandbox + inline `[[hooks.<Event>]]` blocks)
- Subagents: `.codex/agents/<name>.toml` (one per role, `gpt-5.5` for reviewers/heads, `gpt-5.4-mini` for fast tasks)
- Instructions: `.codex/AGENTS.md` (generated from this file)
- Default model: `gpt-5.5` (no free tier; you need an OpenAI plan or API key)

**Trust model.** Codex loads project-local `.codex/` only when the project is trusted. On first run, the TUI will prompt to trust the project (and the hook commands). To skip the prompt: `codex --dangerously-bypass-hook-trust`. To manage trust later: run `/hooks` in the Codex TUI.

**apply_patch caveat.** Codex's native file-edit tool is `apply_patch`, which uses a custom patch format (not standard unified diff). The `require-active-ticket` gate uses the matcher `apply_patch|Edit|Write` to catch these, and the hook reads `tool_input.command` for the file path. If you bypass the bash tool and use `apply_patch` directly, the gate still fires via the file-edit matcher.

**Validation.** Run `codex doctor` to confirm your config and hooks load correctly. Expect "0 fail" at the bottom.

## Syncing from upstream

To pull the latest `apexyard` improvements into your fork while keeping your customisations:

```bash
bun run bin/sync-from-upstream.sh
```

This fetches `upstream/main`, surfaces a diff, and lets you cherry-pick the changes you want.

## More

- Full setup guide: `docs/multi-project.md`
- Quick start: `docs/getting-started.md`
- Rule audit: `docs/rule-audit.md`
- AgDR library: `docs/agdr/`

# apexyard OpenCode + Codex Migration — Design

**Date:** 2026-06-04
**Author:** apexyard maintainer
**Status:** Draft — pending user approval
**Scope:** Full replacement of Claude Code harness with OpenCode + OpenAI Codex CLI

---

## 1. Problem

The apexyard framework is 100% coupled to Claude Code:

- `.claude/settings.json` uses Claude Code's hook schema (`PreToolUse`, `PostToolUse`, `SessionStart`, `UserPromptSubmit`)
- All 31 hooks reference `${CLAUDE_CODE_SESSION_ID}` env var
- `CLAUDE.md` is the Claude Code entry point
- 23 agent frontmatter files use `model: opus` and Claude Code's tool naming (`mcp__apexyard-search__search_docs`)
- 53 skills use Claude Code's frontmatter keys (`disable-model-invocation`, `argument-hint`, `effort`)
- Docs reference `/plugin marketplace add anthropics/claude-plugins-official`

The user wants the framework to work with:
- **OpenCode** harness (`.opencode/`, `opencode.json`)
- **OpenAI Codex CLI** harness (`.codex/`, `config.toml`, `AGENTS.md`)
- **OpenAI GPT models** available for critical agents (review, security, architecture)
- **Free OpenCode models** (`opencode/minimax-m3-free`) as the default for routine agents
- The fork is fully owned by the user (no upstream PRs); upstream remote kept for sync only

**Default model policy:** free models by default (cost-effective); GPT-5 auto-selected for the agents listed in `shared/config/defaults.json → tiered_agents`. Users can override per-agent via the local gitignored config.

---

## 2. Goals & Non-Goals

### Goals

- apexyard runs under OpenCode with zero Claude Code dependency
- apexyard runs under OpenAI Codex CLI with the same feature set
- All 31 hooks, 53 skills, 23 agents, 11 rules migrate 1:1
- Single source of truth (`shared/`) generates both `.opencode/` and `.codex/` via one generator
- Free models (`opencode/minimax-m3-free`) are the default; GPT-5 selected for tier-2 agents (review, security, architecture heads)
- Git workflow preserved (PRs to user's own fork, dev→main release-cut branch model)

### Non-Goals

- Backwards compatibility with Claude Code (the `.claude/` directory is removed entirely)
- Migration tools for existing apexyard forks using Claude Code (manual only)
- Adding Codex CLI features that don't have an OpenCode counterpart
- Replacing the .ts tooling with anything other than TypeScript + Node (locked decision)

---

## 3. Decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Brand | Keep "apexyard" name; full rebrand of Claude Code → OpenCode/Codex |
| D2 | Target harnesses | OpenCode + OpenAI Codex CLI (both) |
| D3 | Source of truth | Single canonical source (`shared/`) + generator |
| D4 | Generator language | TypeScript + Node (`bin/sync.ts` via `tsx`) |
| D5 | Hook strategy | 1:1 migration; core logic in `shared/hooks/*.ts`; OpenCode composes one plugin, Codex shell-outs to TS |
| D6 | Model strategy | Tiered — free (`opencode/minimax-m3-free`) for tier-1, GPT-5 for tier-2 (review/security/heads) |
| D7 | Scope | Full migration, all in one go (no MVP) |
| D8 | Multi-project | Yes, same model (registry + workspace + per-project docs) |
| D9 | Upstream | Keep `upstream` remote for sync; `origin` is user's own fork |
| D10 | License | MIT (unchanged) |

---

## 4. Architecture

### 4.1 Directory Layout

```
apexyard/
├── INSTRUCTIONS.md                   # NEW: canonical instructions (replaces CLAUDE.md)
├── AGENTS.md                         # Universal entry point (already exists, updated)
├── shared/                           # SOURCE OF TRUTH
│   ├── roles/                        # 23 agents as YAML
│   │   ├── engineering/
│   │   │   ├── code-reviewer.yaml
│   │   │   ├── backend-engineer.yaml
│   │   │   └── ...
│   │   ├── product/
│   │   ├── design/
│   │   ├── security/
│   │   └── data/
│   ├── skills/                       # 53 skills as YAML
│   │   ├── setup.yaml
│   │   ├── start-ticket.yaml
│   │   └── ...
│   ├── hooks/                        # 31 hooks as TypeScript modules
│   │   ├── require-active-ticket.ts
│   │   ├── require-migration-ticket.ts
│   │   └── ...
│   ├── rules/                        # 11 rule .md files
│   │   ├── workflow-gates.md
│   │   ├── pr-workflow.md
│   │   └── ...
│   └── config/
│       ├── defaults.json             # provider, default model, tiered agents
│       └── schema.json               # JSON Schema for the canonical config
├── .opencode/                        # GENERATED — do not edit by hand
│   ├── opencode.json
│   ├── plugin/
│   │   └── apexyard-hooks.ts         # composes all shared/hooks/*
│   ├── agent/                        # generated from shared/roles/
│   ├── skill/                        # generated from shared/skills/
│   └── instructions/                 # generated from INSTRUCTIONS.md
├── .codex/                           # GENERATED — do not edit by hand
│   ├── config.toml                   # Codex CLI global config
│   ├── AGENTS.md                     # generated subset of INSTRUCTIONS.md
│   └── hooks/                        # bash wrappers calling shared/hooks/* via tsx
│       ├── require-active-ticket.sh
│       └── ...
├── bin/
│   ├── sync.ts                       # TypeScript generator
│   ├── sync.sh                       # shell wrapper (delegates to tsx)
│   ├── apexyard                      # briefing command (existing)
│   └── sync-from-upstream.sh         # fetch upstream main, diff, cherry-pick
├── docs/                             # adopter docs (updated for new harness)
├── handbooks/                        # unchanged
├── templates/                        # unchanged
├── workflows/                        # unchanged
├── roles/                            # LEGACY → kept for human-readable role descriptions
├── onboarding.yaml                   # unchanged
├── apexyard.projects.yaml.example    # unchanged
├── package.json                      # NEW: tsx, js-yaml, ajv, @opencode-ai/plugin
├── tsconfig.json                     # NEW
├── LICENSE                           # MIT
└── README.md                         # updated to describe new architecture
```

### 4.2 Generator Flow (`bin/sync.ts`)

**Inputs:** `shared/`
**Outputs:** `.opencode/` and `.codex/`

1. Read every `shared/roles/*.yaml` → write `.opencode/agent/<name>.md` (frontmatter + body)
2. Read every `shared/skills/*.yaml` → write `.opencode/skill/<name>/SKILL.md`
3. Compose all `shared/hooks/*.ts` into `.opencode/plugin/apexyard-hooks.ts` (single exported plugin)
4. Generate `.opencode/opencode.json` from `shared/config/defaults.json` + collected agent metadata
5. Generate `.codex/config.toml` from the same defaults
6. Generate `.codex/AGENTS.md` as a subset of `INSTRUCTIONS.md` (Codex-friendly sections only)
7. Generate `.codex/hooks/<name>.sh` bash wrappers for each hook
8. Validate: run `ajv` against `opencode.json` schema; fail with non-zero exit on error
9. Print diff: `git diff --stat .opencode/ .codex/`

**Dependencies:** `tsx` (runtime), `js-yaml` (YAML parsing), `ajv` + `ajv-formats` (validation), `@opencode-ai/plugin` (types)

---

## 5. Source-of-Truth Format

### 5.1 Role YAML (`shared/roles/<dept>/<name>.yaml`)

```yaml
name: backend-engineer
persona: Karim
department: engineering
model: opencode/minimax-m3-free
fallback_model: openai/gpt-5
description: Backend engineer. Implements domain logic + API layer.
mode: subagent
permission:
  edit: allow
  bash: ask
  webfetch: deny
prompt_file: roles/engineering/karim.md   # body reused from existing role file
```

### 5.2 Skill YAML (`shared/skills/<name>.yaml`)

```yaml
name: setup
description: First-run framework bootstrap — 3 exchanges (describe stack → defaults → accept/customize).
effort: medium
argument_hint: "[--reset] [--enable-lsp]"
body_file: skills/setup/SKILL.md
```

### 5.3 Hook TypeScript (`shared/hooks/<name>.ts`)

```ts
import type { Plugin } from "@opencode-ai/plugin"

export default (async () => ({
  "tool.execute.before": async (input, output) => {
    if (!["edit", "write", "bash"].includes(input.tool)) return
    // ... ported logic from .claude/hooks/<name>.sh
  }
})) satisfies Plugin
```

### 5.4 Config JSON (`shared/config/defaults.json`)

```json
{
  "providers": {
    "opencode": { "enabled": true },
    "openai": { "apiKey": "${OPENAI_API_KEY}" }
  },
  "default_model": "opencode/minimax-m3-free",
  "default_small_model": "opencode/minimax-m3-free",
  "tiered_agents": {
    "code-reviewer": "openai/gpt-5",
    "security-reviewer": "openai/gpt-5",
    "penetration-tester": "openai/gpt-5",
    "head-of-*": "openai/gpt-5"
  },
  "gates": {
    "ticket_first": true,
    "merge_two_marker": true,
    "branch_name_enforced": true,
    "pr_title_enforced": true,
    "no_main_push": true,
    "no_git_add_all": true,
    "secrets_scanning": true
  }
}
```

---

## 6. Target Formats

### 6.1 OpenCode (`.opencode/opencode.json`)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/minimax-m3-free",
  "small_model": "opencode/minimax-m3-free",
  "default_agent": "build",
  "instructions": [".opencode/instructions/INDEX.md"],
  "provider": {
    "opencode": {},
    "openai": { "options": { "apiKey": "{env:OPENAI_API_KEY}" } }
  },
  "agent": {
    "code-reviewer": { "model": "openai/gpt-5" },
    "security-reviewer": { "model": "openai/gpt-5" }
  },
  "permission": { "edit": "ask", "bash": "ask" },
  "mcp": {}
}
```

- `.opencode/agent/<name>.md` — frontmatter (`name, model, mode, description, permission`) + body
- `.opencode/skill/<name>/SKILL.md` — frontmatter (`name, description`) + body
- `.opencode/plugin/apexyard-hooks.ts` — single composed plugin exporting all 31 hook functions

### 6.2 Codex CLI (`.codex/`)

**`config.toml`:**
```toml
model = "opencode/minimax-m3-free"
model_reasoning_effort = "medium"
approval_policy = "on-request"
sandbox = "workspace-write"

[agents.code-reviewer]
model = "openai/gpt-5"

[agents.security-reviewer]
model = "openai/gpt-5"

[hooks.pre_tool_use]
command = ["bash", ".codex/hooks/require-active-ticket.sh"]
```

**`AGENTS.md`:** Subset of `INSTRUCTIONS.md` containing sections Codex understands (no Claude-Code-specific tool names, no environment variables Codex doesn't expose).

**`hooks/<name>.sh`:** Bash wrappers that read JSON from stdin (Codex hook protocol) and shell-out to `tsx shared/hooks/<name>.ts` with the relevant args.

---

## 7. Hook Migration (1:1)

| Claude Code hook | OpenCode event | Codex hook |
|---|---|---|
| `PreToolUse Edit\|Write` | `tool.execute.before` (edit, write) | `pre_tool_use` matcher `apply_patch` |
| `PreToolUse Bash` | `tool.execute.before` (bash) | `pre_tool_use` matcher `shell` |
| `PostToolUse Bash(gh pr create)` | `tool.execute.after` (bash) | `post_tool_use` matcher `shell` |
| `SessionStart` | Custom plugin event (session.boot) | `session_start` |
| `UserPromptSubmit` | `chat.message` | `user_prompt_submit` |

**Common abstraction:** Each `shared/hooks/<name>.ts` exports `evaluate(input, output)`. Generator produces:
- OpenCode: TypeScript wrapper that calls `evaluate`
- Codex: bash script that pipes stdin JSON to `tsx shared/hooks/<name>.ts` and writes the result to stdout

**Trade-off:** Codex's hook system is bash-only, so the bash wrapper adds latency (~50–200ms per hook call) but keeps core logic in one place.

---

## 8. Model Tiering

| Tier | Model | Agents |
|------|-------|--------|
| Tier 1 (free) | `opencode/minimax-m3-free` | backend-engineer, frontend-engineer, platform-engineer, sre, qa-engineer, product-manager, product-analyst, ui-designer, ux-designer, data-analyst, data-engineer, ticket-manager, dep-auditor |
| Tier 2 (paid) | `openai/gpt-5` | code-reviewer, security-reviewer, penetration-tester, head-of-engineering, head-of-product, head-of-design, head-of-security, head-of-data, tech-lead |

Selection rule: `bin/sync.ts` reads `shared/config/defaults.json → tiered_agents` and applies to each agent. Glob patterns (`head-of-*`) match all matching agent names. User overrides win via local `.opencode/opencode.json` (gitignored).

---

## 9. Migration Steps (Cleanup of `.claude/`)

1. **Bootstrap** — create `shared/`, `package.json`, `tsconfig.json`, `bin/sync.ts`. First run produces skeleton.
2. **Port roles (23)** — convert each `roles/<dept>/<role>.md` to `shared/roles/<dept>/<role>.yaml` pointing to a `body_file`. Sync → `.opencode/agent/`.
3. **Port skills (53)** — convert each `.claude/skills/<name>/SKILL.md` to `shared/skills/<name>.yaml` pointing to `body_file`. Sync → `.opencode/skill/`.
4. **Port hooks (31)** — convert each `.claude/hooks/<name>.sh` to `shared/hooks/<name>.ts`. Sync → OpenCode composed plugin + Codex bash wrappers.
5. **Port rules (11)** — move `.claude/rules/*.md` → `shared/rules/*.md`. Sync → `.opencode/instructions/`.
6. **Author INSTRUCTIONS.md** — write the canonical, harness-agnostic instructions (replaces `CLAUDE.md`). Generator slices it for `.codex/AGENTS.md`.
7. **Branding cleanup** — delete `CLAUDE.md` (or convert to redirect), strip `me2resh/apexyard` references from docs, update `README.md` and `docs/getting-started.md` and `docs/multi-project.md`, rename `package.json` to `apexyard`.
8. **Remove `.claude/`** — once `.opencode/` and `.codex/` enforce the same gates via tests, delete `.claude/` entirely. The `.claude/hooks/tests/` regression suite is ported to `bin/hooks.test.ts`.
9. **Update git remotes** — `origin` = user's fork; `upstream` = `me2resh/apexyard` (sync only). `bin/sync-from-upstream.sh` does the cherry-pick dance.

---

## 10. Tests & Verification

- **Generator tests** (`bin/sync.test.ts`, Jest): YAML → opencode.json validation, agent frontmatter shape, skill description non-empty
- **Hook tests** (`bin/hooks.test.ts`, port of `.claude/hooks/tests/`): 30+ test cases adapted to OpenCode plugin testing harness
- **E2E in CI:** run `bin/sync.ts` on fixture `shared/`, assert files generated, assert `opencode.json` parses against `https://opencode.ai/config.json` schema
- **Smoke test:** `opencode --config .opencode/opencode.json "test the setup"` and `codex --config .codex/config.toml "test the setup"` produce a non-empty response and respect the active-ticket gate

---

## 11. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| OpenCode plugin API has no per-tool matcher regex (unlike Claude Code's `if: "Bash(git add *)"`) | Single plugin filters all bash commands via regex internally |
| Codex hooks are bash-only; complex hooks (e.g. `require-migration-ticket.sh`) become long bash | Core logic in `shared/hooks/*.ts`; bash wrapper is thin |
| 31 hooks × TS rewrite is a big chunk of work | Extract common lib (`shared/hooks/_lib/*.ts`); shell-out wrappers are thin |
| Some Codex CLI models may not be available in user's region | Verify availability at `bin/sync.ts` startup; fall back to OpenCode free model |
| `MCP` server names differ between Claude Code and OpenCode | Update `mcp__apexyard-search__search_docs` references in agents to use OpenCode's MCP schema |

---

## 12. Out of Scope (Explicit Non-Goals)

- Per-model cost tracking / usage dashboards
- Multi-tenant setups (single-user fork)
- Migration tooling for Claude-Code-using forks
- Syncing the user's own fork back to `me2resh/apexyard` upstream

---

## 13. Acceptance Criteria

- [ ] `bin/sync.ts` runs cleanly on a fresh clone with empty `shared/` (produces valid `.opencode/` and `.codex/`)
- [ ] All 23 agents appear in `.opencode/agent/`
- [ ] All 53 skills appear in `.opencode/skill/`
- [ ] All 31 hooks fire correctly under OpenCode (validated by `bin/hooks.test.ts`)
- [ ] `.codex/config.toml` parses and `codex` CLI accepts it
- [ ] Default agent uses `opencode/minimax-m3-free`; `code-reviewer` uses `openai/gpt-5`
- [ ] `INSTRUCTIONS.md` exists and `.codex/AGENTS.md` is a working subset
- [ ] `.claude/` is removed from the repo
- [ ] `bin/sync-from-upstream.sh` fetches upstream main and surfaces a clean diff
- [ ] `LICENSE` (MIT) is unchanged
- [ ] `README.md` describes the new OpenCode + Codex architecture

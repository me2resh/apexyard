# AgDR-0070 — Model-neutral ApexYard refactor (.claude/ → .apexyard/)

> In the context of ApexYard being wired exclusively for Claude Code, facing the risk that the framework locks adopters into a single agent/tool vendor and cannot support Kimi Code CLI or future tools without forking the framework itself, I decided to move the canonical framework content from `.claude/` to `.apexyard/` and treat `.claude/` and `.kimi-code/` as generated registration layers synced by `bin/apexyard-sync-tool-dirs`, rather than maintaining tool-specific canonical copies or hand-porting hooks per tool, to achieve a single source of truth that is agent/tool-neutral and makes adding new tools a registration-layer problem, accepting the one-time migration cost for existing adopters and the need for a sync guard in CI.

## Context

- ApexYard's mechanical enforcement hooks, skills, agents, rules, and registries lived under `.claude/`. This made sense when the only supported tool was Claude Code, but it meant every framework file was implicitly Claude-specific even when the logic was generic shell.
- Kimi Code CLI adoption inside the core team surfaced a second tool that needed the same hooks. Copying `.claude/` to `.kimi-code/` by hand would create two canonical sources that drift, and future tools (Codex, etc.) would multiply the problem.
- The framework already had the concept of an ops fork and tool-neutral concepts (ops-root walk, session state, portfolio registry). The directory layout was the remaining Claude-specific assumption.
- A model-neutral canonical layer lets the framework ship one set of hooks/skill specs/agent prompts and generate per-tool wiring (`settings.json`, `config.toml`, dispatchers) from it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| 1. **Move canonical content to `.apexyard/`; generate `.claude/` and `.kimi-code/`** (chosen) | Single source of truth; new tools add only a registration layer; sync is mechanical and CI-guarded; adopter overrides live in `.apexyard/project-config.json` regardless of tool | One-time migration for existing adopters; `.claude/settings.json` remains hand-maintained because it contains tool-specific wiring |
| 2. Keep `.claude/` canonical and mirror into `.kimi-code/` manually | Zero change to existing Claude-only adopters | Guaranteed drift; every future tool repeats the work; conceptually wrong (framework logic is not Claude-specific) |
| 3. Introduce a new top-level `framework/` dir and keep `.claude/` as legacy | Cleaner naming than `.apexyard/` | Breaks the established `.apexyard/` convention already used for `project-config.json`, `session/`, and `migrations/`; bigger rename surface |
| 4. Per-tool canonical dirs with shared libs only | Each tool can have tool-idiomatic wiring | Abandons the goal of a single source of truth; complexity scales with number of tools |

## Decision

Chosen: **Option 1 — `.apexyard/` becomes canonical; `.claude/` and `.kimi-code/` are generated.**

- `.apexyard/` now holds hooks, skills, agents, rules, migrations, registries, and project config as the source of truth.
- `bin/apexyard-sync-tool-dirs` copies canonical content into `.claude/` and `.kimi-code/`, preserving hand-maintained protected files (`settings.json`, `settings.local.json`, `KIMI.md`, `config.toml`).
- `.claude/settings.json` is hand-maintained and its wrapper commands exec `.apexyard/hooks/<name>.sh`.
- `templates/kimi-setup/` provides the Kimi dispatcher and example `config.toml` so Kimi users can wire the same hooks.
- `.github/workflows/tool-dirs-sync.yml` fails CI if generated directories drift from `.apexyard/`.
- Existing adopters run `.apexyard/migrations/v3.1.4-to-v4.0.0.sh` during `/update` to move `.claude/project-config.json` → `.apexyard/project-config.json` and `.claude/session/` → `.apexyard/session/`.

## Consequences

- Adding a future tool (e.g., Codex, Windsurf, local LSP orchestrator) requires only a new adapter/dispatcher and a CI sync guard, not a hand-mirror of the framework.
- Adopter customisations (project-config, session state, custom skills via symlinks) now live in `.apexyard/` and survive regardless of which tool drives the session.
- The migration is breaking for existing forks: `.claude/` is no longer canonical and is regenerated. The v3.1.4→v4.0 migration script handles the common adopter-local moves.
- Framework maintainers must edit `.apexyard/` only and run `bin/apexyard-sync-tool-dirs` before committing; CI enforces this.
- `.claude/settings.json` remains the one hand-maintained tool file because its JSON shape is Claude-specific and cannot be derived mechanically from `.apexyard/` content.

## Artifacts

- Ticket: me2resh/apexyard#649
- Branch: `refactor/GH-649-model-neutral-apexyard`
- Touches: `.apexyard/`, `.claude/`, `.kimi-code/`, `bin/apexyard-sync-tool-dirs`, `bin/extract-subpacks.sh`, `templates/kimi-setup/`, `docs/`, `agent-routing.yaml.example`, `CHANGELOG.md`, `KIMI.md`, `.github/workflows/tool-dirs-sync.yml`
- Migration: `.apexyard/migrations/v3.1.4-to-v4.0.0.sh`

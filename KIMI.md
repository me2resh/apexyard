# ApexYard — Kimi Code CLI Setup

You are the **Chief of Staff** running a portfolio of projects inside ApexYard. The canonical framework content lives in `.apexyard/`; `.kimi-code/` is a generated copy kept in sync by `bin/apexyard-sync-tool-dirs`.

## Setup

1. Read `AGENTS.md` for the universal repo layout and constraints.
2. Read `onboarding.yaml` and `apexyard.projects.yaml`.
3. Ensure hooks are registered in your Kimi Code CLI config (`~/.kimi-code/config.toml`). A typical registration uses the dispatcher at `~/.kimi-code/hooks/apexyard-dispatch.sh` to locate `.apexyard/hooks/<name>.sh` in the current project tree.
4. Run `bin/apexyard-sync-tool-dirs` whenever you modify files under `.apexyard/` so `.kimi-code/` stays in sync.

## Workflow

- Work through the SDLC in `workflows/sdlc.md`.
- Follow the mechanical rules in `.apexyard/rules/`.
- Use the slash-command skills in `.apexyard/skills/`.
- Activate specialist agents from `.apexyard/agents/` when role triggers fire.

## Hooks

All enforcement hooks are in `.apexyard/hooks/` and are copied to `.kimi-code/hooks/` by the sync script. The Kimi dispatcher in `~/.kimi-code/hooks/apexyard-dispatch.sh` walks up from `$PWD` and execs the matching hook from `.apexyard/hooks/`.

## Important note for contributors

When editing framework hooks, skills, agents, or rules, edit the files under `.apexyard/` only. Generated copies under `.kimi-code/` and `.claude/` are recreated by `bin/apexyard-sync-tool-dirs`. CI will fail if the generated directories are out of sync.

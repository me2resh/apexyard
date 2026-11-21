---
id: AgDR-0294
timestamp: 2026-11-10T19:13:50Z
agent: platform-engineer (Adel)
model: claude-opus-5-5
session: me2resh/apexyard#2033 build
trigger: user-prompt
status: executed
category: architecture
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Declare model and effort tiers in one map

> In the context of per-agent model lines, facing many edits per model change, I decided to make `.claude/harness-models.json` a tier map with a sync script, to make a model change one line, accepting generated copies in agent files.

## Context

Ticket me2resh/apexyard#2033 asks for one file that maps each agent to a tier.
Each tier must map to a model and an effort for each harness.
Before this change, each agent file named its own model and effort.
The Codex adapter mapped a model label to a Codex model through `.claude/harness-models.json`.

These constraints apply:

- Claude Code reads `model:` and `effort:` only from the agent frontmatter. An agent file cannot name a tier.
- The SessionStart routing hook `.claude/hooks/apply-agent-routing.sh` rewrites `model:` lines in the working tree. It must keep working without a change.
- The hooks stay frozen until the 17 to 18 Nov bypass self-test. No file under `.claude/hooks/` changes, except new tests.
- The drift guard `.claude/hooks/block-agent-routing-drift.sh` blocks a committed model that differs from the `dev` model. The escape-hatch comment `# routing-config:override <reason>` allows a deliberate change.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Agent files name only a tier, and a hook resolves the tier at session start | Agent files hold no copy | Needs a hook change during the freeze. A fresh clone has no valid model until the hook runs. |
| A new map file next to `.claude/harness-models.json` | Leaves the Codex map shape unchanged | Two files hold model facts. A model change can touch both. |
| Extend `.claude/harness-models.json` to schema 2, and generate the frontmatter with a sync script and `--check` | One file. Agent files stay valid for Claude Code. No hook change. The pattern matches `bin/sync-codex-adapter.sh --check`. | Agent files keep generated copies. A model change needs the sync run and the escape-hatch comment. |

## Decision

Chosen: **extend `.claude/harness-models.json` to schema 2 with a sync script**.
This option gives one source without a hook change.
It also keeps every agent file valid for Claude Code.

The map has four sections:

1. `tiers`: `reason` (rank 3), `build` (rank 2), and `light` (rank 1). Each tier sets a `claude` model and effort and a `codex` model and effort.
2. `agents`: each agent file maps to a tier. An optional `effort` overrides the tier effort. The value `inherit` removes the `effort:` line.
3. `stages`: `planning` and `review` are `high`. `build` and `scan` are `medium`. `status` is `low`.
4. `skills`: each skill that already declares effort maps to a stage.

`bin/sync-agent-tiers.sh` writes `model:` and `effort:` into each mapped agent file. It writes `effort:` into each mapped `SKILL.md`. `--check` writes nothing and exits 1 on drift.

The script reads `.claude/agents/.framework-defaults.json`. The routing hook writes that file for each agent that it rewrote. The script leaves a routed `model:` line unchanged in both modes. The script still checks and writes `effort:`.

`bin/sync-codex-adapter.sh` finds the tier whose `claude.model` equals the agent model, and it writes that tier's `codex.model`. It writes `model_reasoning_effort` from the agent effort or the tier effort. A schema 1 file still works. A model with no tier passes through unchanged.

These agent decisions apply:

- Reviewers (`code-reviewer`, `security-reviewer`, `solution-architect`) use the `reason` tier. Builders use the `build` tier. A test checks the rank order.
- `qa-engineer` moves from `haiku` to the `build` tier (`sonnet`, effort `medium`). It now runs exact-SHA checks before merge.
- Each department head gets effort `high`, because head work is planning and decision work.
- `tech-lead` and `sre` keep `opus` with effort `medium` through an agent effort override.
- `penetration-tester`, `dependency-auditor`, `product-analyst`, and `data-analyst` keep an unset effort through `inherit`. The earlier effort decision in `docs/agents/effort.md` left them unset for measurement.

Skills use five stages, not four. The `scan` stage holds the single-dimension audits at `medium`. This keeps every current skill effort unchanged.

## Consequences

- A model change is one line in `.claude/harness-models.json`, then one sync run.
- The drift guard still asks for the escape-hatch comment on each agent whose committed model changes. A later hook change can read the tier map instead. The hook freeze defers that change.
- The pre-push check set runs `--check`. CI runs it in `.github/workflows/agent-tier-map.yml` and in `.claude/agents/tests/test_agent_tier_map.sh`.
- An adopter routing override still applies. A local `--check` accepts the routed model. CI has no routing file, so CI checks every model.
- Agent files and skills outside the map stay unchanged. The script prints a note for each one.
- Ticket me2resh/apexyard#2027 reduces the agent roster. That change must update the `agents` section of the map.

## Artifacts

- Ticket: me2resh/apexyard#2033
- Map: `.claude/harness-models.json`
- Script: `bin/sync-agent-tiers.sh`
- Tests: `.claude/agents/tests/test_agent_tier_map.sh`

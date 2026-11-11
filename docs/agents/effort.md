# Agent model and effort

The tier map sets the model and the effort for each agent.
The map also sets the effort for each skill that declares effort.
The map is [`.claude/harness-models.json`](../../.claude/harness-models.json).
[AgDR-0294](../agdr/AgDR-0294-model-and-effort-tier-map.md) records the design.

Effort controls reasoning depth for an agent turn.
An explicit value keeps an agent independent of the parent session's effort.
An unset effort inherits the session setting.

## Terms

| Term | Meaning |
| --- | --- |
| Tier | A class of work: `reason`, `build`, or `light`. A tier sets a model and an effort for each harness. |
| Tier map | The file `.claude/harness-models.json`. It holds the tiers, the agent tiers, the stages, and the skill stages. |
| Stage | A kind of skill work, for example planning or review. A stage sets one effort. |
| `inherit` | An agent effort value that removes the `effort:` line. The agent then uses the session effort. |

## Tiers

| Tier | Rank | Claude Code | Codex |
| --- | --- | --- | --- |
| `reason` | 3 | `opus`, effort `high` | `gpt-5.5`, effort `high` |
| `build` | 2 | `sonnet`, effort `medium` | `gpt-5.4`, effort `medium` |
| `light` | 1 | `haiku`, effort `low` | `gpt-5.4-mini`, effort `low` |

Reviewers stay on a higher rank than builders.
Per AgDR-0087, keep the `reason` tier on the strongest model of each harness.

## Agents

An agent uses the effort of its tier unless the map gives an agent effort.

| Agent | Tier | Effort | Reason |
| --- | --- | --- | --- |
| Code Reviewer (Rex) | reason | high | Checks correctness and review evidence. |
| Security Reviewer (Hakim) | reason | high | Examines threats and security boundaries. |
| Solution Architect (Tariq) | reason | high | Tests design assumptions and trade-offs. |
| Contrarian (Naqid) | reason | high | Challenges premises and finds counterarguments. |
| Head of Engineering | reason | high | Makes cross-project engineering decisions. |
| Penetration Tester | reason | unset | Specialized testing needs separate measurement before tuning. |
| Tech Lead | reason | medium | Authors designs and coordinates implementation. |
| SRE | reason | medium | Implements reliability and observability changes. |
| Backend Engineer | build | medium | Implements scoped application changes. |
| Frontend Engineer | build | medium | Implements scoped interface changes. |
| Platform Engineer | build | medium | Builds infrastructure and tooling. |
| Data Engineer | build | medium | Builds data pipelines and models. |
| UI Designer | build | medium | Authors component and visual specifications. |
| UX Designer | build | medium | Authors flows and interaction specifications. |
| Product Manager | build | medium | Authors requirements and acceptance criteria. |
| QA Engineer | build | medium | Runs exact-commit checks before merge. |
| Head of Product | build | high | Makes roadmap and feasibility decisions. |
| Head of Design | build | high | Makes design-system and visual-standard decisions. |
| Head of Security | build | high | Makes security strategy and compliance decisions. |
| Head of Data | build | high | Makes data governance and reporting decisions. |
| Dependency Auditor | build | unset | Retains inherited effort for utility checks. |
| Product Analyst | build | unset | Research needs vary by assignment. |
| Data Analyst | light | unset | Analysis needs vary by assignment. |

## Skill stages

The map sets effort only for a skill that already declares effort.

| Stage | Effort | Skills |
| --- | --- | --- |
| planning | high | `split-portfolio` |
| review | high | `accessibility-audit`, `compliance-check`, `launch-check`, `threat-model` |
| build | medium | `debug`, `fan-out`, `journey`, `onboard`, `setup` |
| scan | medium | `analytics-audit`, `docs-audit`, `geo-audit`, `monitoring-audit`, `performance-audit`, `seo-audit` |
| status | low | `approve-architecture`, `approve-design`, `approve-merge`, `start-ticket`, `tutorial` |

## Change a model or an effort

1. Edit one line in `.claude/harness-models.json`.
2. Run `bash bin/sync-agent-tiers.sh` to write the agent and skill files.
3. Run `bash bin/sync-agent-tiers.sh --check` to confirm that no drift remains.
4. Commit the map and the changed files together.

A changed `model:` line also needs the escape-hatch comment in that agent file.
The routing drift guard compares each committed model with the `dev` model.
Add `# routing-config:override <reason>` to the agent frontmatter.

The pre-push checks run `--check`. CI runs it in the `agent tier map` workflow and in `.claude/agents/tests/test_agent_tier_map.sh`.

## Routing overrides

An adopter can still route one agent to another model with `agent-routing.yaml`.
The SessionStart routing hook rewrites the `model:` line in the working tree.
The hook records each rewritten agent in `.claude/agents/.framework-defaults.json`.
The sync script reads that file and leaves a routed `model:` line unchanged.
The script still checks and writes `effort:` on a routed agent.

## How to measure

The owner must record the before and after results in the PR. No token-consuming measurement ran for this change.

1. Select one accepted PR review and freeze its reviewed commit and input context.
2. Record the baseline effort inherited from its parent session.
3. Repeat the same review with the explicit effort, keeping the model, tools, and input context fixed.
4. Use the [token-cost reviewer view](../perf/token-cost.md) with explicit transcript paths to record tokens for each run.
5. Use [eval-agents](../eval-agents/README.md) with the same labeled entry to compare review findings against frozen ground truth.
6. Follow the evaluation isolation protocol and keep evaluation reviews away from the live PR.
7. Record both efforts, commit, tokens, findings, corrections needed, and evidence links in the PR.

Count corrections needed as owner-adjudicated changes required to make each review accurate and complete.
Keep cache-read tokens separate, as the token-cost tool specifies. Mark unavailable results as unmeasured.

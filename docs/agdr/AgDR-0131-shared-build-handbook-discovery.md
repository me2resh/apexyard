---
id: AgDR-0131
timestamp: 2026-09-05T08:20:02Z
agent: codex
model: gpt-5
trigger: user-prompt
status: executed
category: patterns
projects: [apexyard]
---

# Share handbook discovery across build agents

> In the context of adding proactive adopter-handbook guidance to four build-class agents, facing drift and token-cost risk from copying Rex's review procedure into every wrapper, I decided to centralize a build-specific discovery contract and reference it from each wrapper to achieve one extensible standard across Build and Review, accepting that agent prompts depend on one additional imported rule file.

## Context

- Rex and Tariq already discover public `handbooks/` and private `custom-handbooks/`, but backend, frontend, platform, and data engineers do not.
- Build agents need the same deterministic bucket selection and optional semantic supplement, while review verdict and enforcement mechanics remain reviewer-owned.
- Agent wrapper files are intentionally thin and already delegate stable behavior to canonical role/rule documents.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Duplicate Rex's full handbook section into all four wrappers | Self-contained prompts; exact review algorithm visible locally | Four large copies drift independently; review-only verdict language can leak into Build; high prompt cost |
| Add one shared build-time discovery rule referenced by all four wrappers | One source of truth; concise wrappers; explicitly separates build guidance from review enforcement | Adds one prompt import dependency; tests must pin that every build wrapper references it |
| Put discovery only in role files | Keeps wrapper metadata minimal | Role files describe human responsibilities and are also read outside agent execution; runtime/tool-specific MCP behavior does not belong there |

## Decision

Chosen: **one shared build-time discovery rule referenced by all four wrappers**, because it reuses Rex's public/private and path-convention semantics without copying review-only ceremony or creating four future maintenance surfaces.

## Consequences

- Architecture/general handbooks always load; language/domain handbooks load from expected or actual implementation paths in both public and private layers.
- Semantic search remains additive and fail-soft, so adopters without MCP retain deterministic discovery.
- Build agents follow handbook guidance and cite it in handoff, but never produce review verdicts or approval markers.
- A regression test fails if any of the four wrappers drops the shared contract or if its required discovery guarantees disappear.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1178
- `.claude/rules/build-handbook-discovery.md`
- `.claude/agents/tests/test_build_handbook_discovery.sh`

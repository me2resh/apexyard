# Agent effort

Effort controls reasoning depth for an agent turn. Explicit values keep these agents independent of the parent session's effort.
Model fields remain unchanged. An unset effort inherits the session setting.

## Settings and reasons

| Agent | Effort | Reason |
| --- | --- | --- |
| Code Reviewer (Rex) | high | Checks correctness and review evidence. |
| Security Reviewer (Hakim) | high | Examines threats and security boundaries. |
| Solution Architect (Tariq) | high | Tests design assumptions and trade-offs. |
| Contrarian (Naqid) | high | Challenges premises and finds counterarguments. |
| Backend Engineer | medium | Implements scoped application changes. |
| Frontend Engineer | medium | Implements scoped interface changes. |
| Platform Engineer | medium | Builds infrastructure and tooling. |
| Tech Lead | medium | Authors designs and coordinates implementation. |
| Data Engineer | medium | Builds data pipelines and models. |
| SRE | medium | Implements reliability and observability changes. |
| UI Designer | medium | Authors component and visual specifications. |
| UX Designer | medium | Authors flows and interaction specifications. |
| Product Manager | medium | Authors requirements and acceptance criteria. |
| Dependency Auditor | unset | Retains inherited effort for utility checks. |
| QA Engineer | unset | Verifies acceptance criteria without building changes. |
| Penetration Tester | unset | Specialized testing needs separate measurement before tuning. |
| Data Analyst | unset | Analysis needs vary by assignment. |
| Product Analyst | unset | Research needs vary by assignment. |
| Head of Engineering | unset | Strategic work needs vary by assignment. |
| Head of Product | unset | Strategic work needs vary by assignment. |
| Head of Design | unset | Strategic work needs vary by assignment. |
| Head of Security | unset | Strategic work needs vary by assignment. |
| Head of Data | unset | Strategic work needs vary by assignment. |

The frontmatter check accepts `low`, `medium`, `high`, `xhigh`, and `max`.
Run `bash .claude/agents/tests/test_agent_wrap_shape.sh` to check the settings.

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

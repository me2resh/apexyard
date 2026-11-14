---
id: AgDR-0301
timestamp: 2026-11-14T12:00:00Z
agent: tech-lead
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# Reduce the agent roster from 23 to 15 without losing expertise

> The framework keeps 15 agents.
> Eight agents merge into five receivers, and no section of their role files is dropped.
> Head-level approvals move to the human approver, so that no agent approves its own work.
> The cost is larger receiver role files and one release of redirect stubs.

## Context

The framework ships 23 agents ([#2027](https://github.com/me2resh/apexyard/issues/2027)).
Five department heads and three specialist roles overlap with the agents they delegate to.
The owner decided on 10 Nov 2026 to reduce the roster to 15 agents.
The owner approved the start of the work on 14 Nov 2026.

Earlier decisions set the current shape:

- [AgDR-0018](AgDR-0018-persona-naming-convention.md) gives each role and agent a persona name.
- [AgDR-0050](AgDR-0050-agent-runtime-overhaul.md) wraps each role file in an agent file and sets the activation class of each role.
- [AgDR-0054](AgDR-0054-solution-architect-role.md) adds Tariq as the independent design reviewer.
- [AgDR-0078](AgDR-0078-the-contrarian-advisory-agent.md) adds Naqid as an advisory challenger with no gate.
- [AgDR-0105](AgDR-0105-retire-lifecycle-agents.md) retires two lifecycle agents and sets the count at 23.
- [AgDR-0106](AgDR-0106-ui-design-gate-authority.md) sets the practitioner-reviews, head-escalates split for UI design.

An agent file is a thin wrapper. The role file holds the expertise.
Thus a merge moves role-file sections, and the agent file of the removed role goes.

The review gates must not change:

- Rex (`code-reviewer`) holds the code-review gate.
- Hakim (`security-reviewer`) holds the security review and keeps read-only tools.
- Tariq (`solution-architect`) holds the architecture gate (Gate 3b).
- Naqid (`contrarian`) stays advisory and writes no marker.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep 23 agents | No change | Heads and practitioners overlap. Two agents can hold one decision. Heads approve the work of agents in their own department. |
| Remove the eight agents, and drop the sections that overlap | Smallest files | Loses expertise: the STRIDE table, the risk matrix, the data-quality standards, the research process. The ticket forbids it. |
| Merge each removed agent into one receiver, move head approvals to the human approver (chosen) | No section is lost. Each review gate keeps its reviewer. No agent approves its own work. | Receiver role files grow. Adopters who name a removed agent must change the name. |

## Decision

Chosen: **merge each removed agent into one receiver, and move head-level approvals to the human approver**.
The human approver is the person that `.review_markers.human_approver_title` names (default `CEO`).
The same person records each per-PR merge approval.

### Roster map (23 agents)

| # | Agent (persona) | Fate | Expertise that moves | Where it lives now |
|---|-----------------|------|----------------------|--------------------|
| 1 | `code-reviewer` (Rex) | Keep | None | Unchanged. Code-review gate. |
| 2 | `security-reviewer` (Hakim) | Keep, receiver | Takes the Head of Security expertise (row 19) | `roles/security/security-auditor.md` |
| 3 | `solution-architect` (Tariq) | Keep | None. Escalations now go to the human approver. | Unchanged. Architecture gate. |
| 4 | `contrarian` (Naqid) | Keep | None | Unchanged. Advisory, no gate. |
| 5 | `dependency-auditor` (Munir) | Keep | None | Unchanged |
| 6 | `tech-lead` (Hisham) | Keep, receiver | Takes the Head of Engineering expertise (row 16) | `roles/engineering/tech-lead.md` |
| 7 | `backend-engineer` (Karim) | Keep | None | Unchanged |
| 8 | `frontend-engineer` (Yasmin) | Keep | None | Unchanged |
| 9 | `platform-engineer` (Adel) | Keep | None | Unchanged |
| 10 | `qa-engineer` (Salim) | Keep | None | Unchanged |
| 11 | `sre` (Saif) | Keep | None | Unchanged |
| 12 | `penetration-tester` (Hamza) | Keep | None | Unchanged |
| 13 | `product-manager` (Mariam) | Keep, receiver | Takes rows 17 and 18 | `roles/product/product-manager.md` |
| 14 | `ui-designer` (Nour) | Keep, receiver, the single designer | Takes rows 20 and 21 | `roles/design/ui-designer.md` |
| 15 | `data-engineer` (Anwar) | Keep, receiver | Takes rows 22 and 23 | `roles/data/data-engineer.md` |
| 16 | `head-of-engineering` (Khalid) | Merge into `tech-lead` | Architecture principles, tech-stack standards, build-or-buy calls, the decision framework, the architecture-review triggers, the quality gates, the delivery metrics, capacity calls | Tech Lead § "Engineering standards" |
| 17 | `head-of-product` (Omar) | Merge into `product-manager` | Roadmap and prioritisation, cross-product allocation, feasibility studies, KPI definitions, the five-point decision framework, stakeholder reports | Product Manager § "Product strategy" |
| 18 | `product-analyst` (Hanan) | Merge into `product-manager` | Market and competitive research, TAM and financial inputs, the research process, source and confidence rules, experiment rigour | Product Manager § "Research" |
| 19 | `head-of-security` (Faisal) | Merge into `security-reviewer` | Security strategy, the trust-chain ownership, the security review process, the STRIDE table, vulnerability response times, the risk matrix, the security standards | Security Auditor § "Security posture" |
| 20 | `head-of-design` (Maha) | Merge into `ui-designer` | Design-system ownership, UX principles, the code-first design approach, the design principles, the design quality standards | UI Designer § "Design system and principles" |
| 21 | `ux-designer` (Iman) | Merge into `ui-designer` | User flows, information architecture, low-fi wireframes, journey previews (`/journey`), UX copy, the UX principles | UI Designer § "User flows and information architecture" |
| 22 | `head-of-data` (Khalil) | Merge into `data-engineer` | Analytics strategy, data governance, portfolio metric definitions, the key-metrics framework, the data-quality standards, the reporting cadence | Data Engineer § "Data strategy and governance" |
| 23 | `data-analyst` (Nadia) | Merge into `data-engineer` | SQL analysis, dashboards, A/B-test rigour, chart selection, the report templates, the analysis documentation standards | Data Engineer § "Analysis and dashboards" |

No agent retires without a receiver. Each removed agent merges.

### Approvals that move to the human approver

| Receiver | Approval that moves to the human approver | Independent review that stays |
|----------|-------------------------------------------|-------------------------------|
| Mariam | PRDs, new ideas, material roadmap changes | Tariq reviews the design. Anwar checks quantitative claims. |
| Hisham | New stacks, architecture principles, major designs | Tariq. Tariq's escalations go to the human approver, not to Hisham. |
| Nour | Design-system and brand changes, design disputes | Salim (flows, browser evidence). Mariam (journeys against the PRD). |
| Hakim | Exceptions to security requirements, risk acceptance | Rex. Hakim keeps read-only tools. |
| Anwar | Data architecture and policy exceptions | Tariq (architecture, migration AgDRs). The migration gate does not change. Hakim (access and privacy). |

This decision supersedes the practitioner-reviews, head-escalates split in AgDR-0106.
Nour still holds the routine per-PR design gate.
A person still records the design verdict with `/approve-design`.
An escalation now goes to the human approver, not to a Head of Design agent.

### Tools

- Mariam already has `WebSearch` and `WebFetch`. They cover the research work of the Product Analyst.
- Hakim keeps `tools: Read, Grep, Glob, Bash, Write` and `disallowedTools: Edit`.
  `limit-reviewer-writes.sh` still limits Write to the review body file.
  Thus Hakim reports a threat model or a policy draft, and a builder or the main thread writes the file.
- Nour keeps the `mcp__playwright__*` entry.
  Gap: the entry works only when the operator runs a Playwright MCP server.
  With no browser server, Nour reports each affected criterion as not browser-verified.
  This gap existed before this change.

### Effort

- `tech-lead` moves from `medium` to the `reason` tier default (`high`).
  Hisham now owns the architecture principles and the stack standards that Khalid held at `high`.
- `product-manager`, `ui-designer` and `data-engineer` stay at `medium`.
  Their head-level work is sparse, and the human approver now makes the head-level decision.
- `security-reviewer` stays at `high`.

### Activation

- Each removed role title still resolves.
  `detect-role-trigger.sh` maps "act as the Head of Product" and the other seven old titles to the receiver role file.
- A removed role keeps a redirect stub under `roles/` for one release.
  The stub names the receiver and has no `## Activation mode` section.
- The next release removes the eight stubs.

## Consequences

- `.claude/agents/` holds 15 agent files.
- `roles/` holds 12 active role files and 8 redirect stubs.
- An adopter whose `agent-routing.yaml` names a removed agent must move the entry to the receiver.
  The routing hook ignores an entry for an agent file that does not exist.
- A custom script that spawns `subagent_type: head-of-security` or another removed slug fails.
  The adopter must use the receiver slug.
- Historical AgDRs, performance baselines, PRDs and technical designs keep the original names.
- The public site quotes the roster counts. A separate site change updates them.

## Artifacts

- Ticket: [#2027](https://github.com/me2resh/apexyard/issues/2027)
- Migration note: [docs/upgrading.md § "Agent roster: 23 to 15"](../upgrading.md#agent-roster-23-to-15)

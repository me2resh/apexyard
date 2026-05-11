# Persona Naming Convention — Classical Arabic Names for All Roles + Agents

> In the context of an SDLC stack with 19 role files and 5 sub-agent files, facing inconsistent persona identity (2 agents named Rex / Shield, 3 agents unnamed, all 19 roles bare-titled), I decided to give every role and agent a classical / historic Arabic persona name carried in a structured `persona_name` field, to achieve consistent team-identity language across conversation, PR comments, and demo scripts, accepting that adopters who want different names must override per-fork by editing the files.

## Context

Before this AgDR, the framework's persona identity was uneven:

- `code-reviewer` shipped as **Rex** (in PR comments, marketing copy, demo scripts)
- `security-reviewer` shipped as **Shield** (PR comments, marketing copy)
- `dependency-auditor` had an internal `**Identity**: Guardian` line, no external use
- `pr-manager` and `ticket-manager` had no persona name at all
- All 19 role files (`roles/engineering/*.md`, `roles/product/*.md`, etc.) had bare titles only — no name

This created three problems:

1. **Conversation friction** — when activating a role mid-session, the framework had no short identifier to refer to. Users had to say "the QA Engineer" every time instead of "Salim".
2. **Inconsistent demos** — the marketing site ([site/index.html](../../site/index.html)) and skills page ([site/skills.html](../../site/skills.html)) named some agents but not others. Demo scripts had Rex prominently and PR-Manager faceless.
3. **No clear naming axis for adopters** — a fork that wants its own team-identity language has no documented "swap these out" point.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Give every role + agent a persona name (chosen)** | Closes the inconsistency. Adds team-identity character. Conversational shorthand for role activation. | Imposes a naming choice on adopters; mitigated by per-fork overrides + structured field. |
| **B. Drop Rex's name and use titles only** | Maximally neutral — no cultural choice imposed by the framework. | Throws away the already-shipped Rex brand equity (downstream conversation history, PR markers, marketing copy). Inconsistency persists between "Rex everywhere in history" and "no name now". |
| **C. Use generic codenames (Alpha / Bravo / Echo)** | Culturally neutral. Easy to remember. | Loses character. Feels like military call-signs, not a team. Collides with NATO phonetic alphabet usage in security/aviation domains. |
| **D. Use vendor-aligned names (e.g. SDK product names)** | Free advertising for upstream tools. | Risks trademark collisions; ties framework identity to third-party brands that may rebrand or fork. |

## Decision

Chosen: **Option A — every role + agent gets a persona name, drawn from classical / historic Arabic names**.

Rationale for the choice of Arabic-name corpus:

1. **Operator preference** — operator (CEO) explicitly approved the mapping table.
2. **Adds team-identity character** without inventing a culturally-blank set.
3. **Gender-mixed** — the 24 selected names include both male and female names (Yasmin, Mariam, Hanan, Maha, Nour, Iman, Nadia are female; Khalid, Hisham, Karim, Salim, Adel, Saif, Omar, Faisal, Hakim, Hamza, Khalil, Anwar, Hatim, Munir, Tariq, Idris are male; Rex remains as-is for brand continuity). This avoids a single-gender "everyone is named X" failure mode.
4. **Avoids shell / vendor collisions** — none of the selected names collide with common shell keywords, vendor product names, or POSIX commands. (`Idris` is also a Linux distribution name and a programming language; in our framework context it's a persona name with no naming-resolution stake.)
5. **Rex stays unchanged** — already-shipped brand equity. Renaming would invalidate PR markers, demo scripts, marketing copy, and downstream conversation history. The cost of renaming Rex outweighs the consistency gain.

### Placement: Option A (YAML frontmatter) for agents, Option B (bold line under H1) for roles

The brief presented two placement options. Both are used, on a clear axis:

- **Agents** (`.claude/agents/*.md`): YAML frontmatter, `persona_name: <Name>`. Agents already have YAML frontmatter consumed by Claude Code (`name`, `description`, `tools`, `model`); adding `persona_name` there is structurally consistent with the existing schema and machine-readable.
- **Role files** (`roles/**/*.md`): bold line under the H1, `**Persona name**: <Name>`. Role files have no existing frontmatter — introducing it here would force adopters to learn a new format for a single field. The bold line under the H1 is human-readable, immediately visible, and consistent with the existing role-file conventions (the next line is `## Identity`, which the persona name fronts naturally).

The split is documented here so adopters can rely on it.

### Full mapping (24 personas, Rex unchanged + 23 renamed)

| Slot | Persona name | Theme |
|------|--------------|-------|
| **Agents** | | |
| code-reviewer | **Rex** (unchanged) | already-shipped brand |
| security-reviewer | **Hatim** | resolute judge |
| dependency-auditor | **Munir** | illuminator |
| pr-manager | **Tariq** | "he who knocks" — PR metaphor |
| ticket-manager | **Idris** | scribe / scholar |
| **Engineering** | | |
| Head of Engineering | **Khalid** | "eternal / leader" |
| Tech Lead | **Hisham** | knowledge-bearer |
| Backend Engineer | **Karim** | generous |
| Frontend Engineer | **Yasmin** | jasmine — aesthetic |
| QA Engineer | **Salim** | "whole / safe" — quality |
| Platform Engineer | **Adel** | just / balanced |
| SRE | **Saif** | sword — incident response |
| **Product** | | |
| Head of Product | **Omar** | long-lived leader |
| Product Manager | **Mariam** | classical |
| Product Analyst | **Hanan** | compassion / empathy |
| **Design** | | |
| Head of Design | **Maha** | grace |
| UI Designer | **Nour** | light |
| UX Designer | **Iman** | faith / trust in flows |
| **Security** | | |
| Head of Security | **Faisal** | decisive judge |
| Security Auditor | **Hakim** | wise judgement |
| Penetration Tester | **Hamza** | "lion" — aggressive |
| **Data** | | |
| Head of Data | **Khalil** | close friend / dependable |
| Data Analyst | **Nadia** | "early dew" — fresh signals |
| Data Engineer | **Anwar** | light / radiant |

## Consequences

- **Conversation idiom** — role activations can now use the short name. "Salim, verify ticket #42" is shorter and more conversational than "Act as the QA Engineer and verify ticket #42". Both forms remain valid; the trigger table in [`.claude/rules/role-triggers.md`](../../.claude/rules/role-triggers.md) is unchanged.
- **Demo scripts and PR comments** stay coherent across agents — every reviewer / orchestrator has a name. The marketing slide at [`site/index.html`](../../site/index.html) and the skills index at [`site/skills.html`](../../site/skills.html) now name all five agents instead of two.
- **Adopters can override per-fork** by editing the `persona_name` field in each agent's YAML frontmatter or the `**Persona name**:` line under each role's H1. No skill or hook reads `persona_name` for matching today, so overriding is purely cosmetic and safe.
- **Rex is the one exception to the rename**. Downstream references in demo scripts, PR markers (the `rex.approved` marker name is unchanged — see `.claude/hooks/block-unreviewed-merge.sh`), and historical conversation memories continue to work without churn.
- **Shield → Hatim**, **Guardian → Munir**: any third-party docs / external blog posts / demo recordings that reference the old names will look dated. Acceptable cost — these are framework-internal names, not API contracts.
- **No machine-readable usage today**, but the structured `persona_name` field in YAML frontmatter enables future hooks or skills to surface the name without parsing prose.

## Artifacts

- Issue: [me2resh/apexyard#204](https://github.com/me2resh/apexyard/issues/204)
- PR: (to be added on creation)
- Files touched:
  - 5 agent files under `.claude/agents/` (frontmatter + body signature lines)
  - 19 role files under `roles/` (bold persona-name line under H1)
  - `CLAUDE.md` (Departments table + agent-list cell + `/security-review` skill row)
  - `site/index.html` (agents marketing slide)
  - `site/skills.html` (skill descriptor referencing Shield)
  - `docs/architecture/apexyard-container.md` (C4 container note)
  - `docs/spikes/claude-model-tier-routing.md` (agent table)

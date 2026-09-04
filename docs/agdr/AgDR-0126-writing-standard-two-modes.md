# Writing standard with two modes and required-core templates

> In the context of ApexYard producing durable artifacts and machine-consumed text that people and agents must act on, facing templates that fill every section whether or not it applies, openings that bury the outcome under scaffolding, and instructions that leave room for interpretation, I decided to add one writing-standard rule with a Strict mode for machine-consumed text and a Flavored mode for durable artifacts, to annotate the core templates with a required core and conditional sections, and to back both with a small regression corpus, to make the outcome and next action visible from the opening without losing voice, uncertainty, or precision, accepting that enforcement stays behavioral and that existing hook messages migrate only when touched.

## Context

- `reporting-style.md` covers in-thread status only and says so. No rule covers how a ticket, PR body, PRD, or hook message should read.
- The templates under `templates/` present every section as equally required. A completed PRD carries an empty Timeline table and an "Approvals" grid with no names; a feature ticket carries "Effort Estimate: TBD" by design.
- Machine-consumed text (hook block messages, spawn briefs, handoff reports) is where ambiguity costs the most: an agent reads "should" as optional and "may" as permission.
- The milestone's kill criterion (me2resh/apexyard#1164) says to narrow ASD-STE100 use if it removes voice, nuance, or precision from human-facing prose, and to keep Strict rules only for machine-consumed text.
- The initiative's anti-scope forbids claiming certified ASD-STE100 compliance, reproducing its dictionary, or applying Strict rules to conversation and marketing copy.
- `evidence-grounding.md` (AgDR-0124) already requires `TBD` over invented values and forbids dropping modality; the writing rule must not contradict it.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **One rule with two modes + template guidance comments + regression cases** | One source of truth; Strict where ambiguity costs, Flavored where judgment matters; templates change by a comment, not a reshuffle; skills that read templates need no edit | Adds a rule file; the Strict backlog in existing hooks migrates gradually |
| Extend `reporting-style.md` to cover artifacts and machine text | No new file | That rule is explicitly about in-thread narration; mixing three readers into one rule makes each guidance weaker |
| Apply one Strict standard to all prose | Simple to state | Strips hedges, rationale, and voice from AgDRs and reports; fails the kill criterion on day one |
| Rewrite every template into a minimal shape | Completed artifacts get shorter immediately | Breaks adopter overrides that mirror the current shape (AgDR-0023); a large diff for a milestone that asks for the smallest correction |
| Add a prose lint hook (sentence length, banned words) | Looks enforceable | Blocks valid precision, passes empty clarity, and cannot see whether a section was needed |

## Decision

Chosen: **one rule with two modes, template guidance comments, and regression cases**, because it gives each reader the mode they need, keeps `reporting-style.md` and `evidence-grounding.md` intact, and changes templates without breaking the path-mirroring override contract.

The rule defines four working rules: open a durable artifact with the outcome, reason, decision, and next action when they exist; keep a small required core and delete conditional sections that have no content; write machine-consumed text in Strict mode (one instruction per sentence, imperative, condition first, exact modality); write durable artifacts in Flavored mode (short and plain, with hedges, numbers, names, and voice kept). Five templates (`prd.md`, `technical-design.md`, `tickets/feature.md`, `tickets/bug.md`, `tickets/task.md`) gain a guidance comment naming their required and conditional sections; `prd.md` gains a Summary opening. `templates/README.md` documents the convention so adopter overrides can adopt it. Approvals stays required in the PRD and the technical design because Gate 1 and Gate 2 (`workflow-gates.md`) read approval from those documents; the fix for an empty grid is to fill it before the document leaves Draft, not to drop the section.

Existing hook messages and agent files are not rewritten in this change. They take the Strict mode when they are next edited, and text under `.claude/hooks/**` still takes the Heavy path.

## Consequences

- `writing-standard.md` becomes the twenty-first rule file. `CLAUDE.md`, `AGENTS.md`, `SYSTEM.md`, and the generated Cursor bridge carry one sentence each and point to it.
- A completed artifact contains only sections with content. `TBD` marks an unknown required value; nothing marks an absent conditional section.
- Ticket skills now read the writing-standard guidance before drafting. Their inline fallback previews still carry the pre-#1164 shape, so each fallback must be cleaned when that skill is next touched.
- The framework does not claim ASD-STE100 certification and ships no restricted dictionary.
- Seven human-adjudicated cases cover the opening, empty sections, placeholders, Strict block messages, Strict spawn briefs, Flavored uncertainty, and the conversation guard. Behavioral scoring belongs to me2resh/apexyard#1165.

## Artifacts

- Ticket: me2resh/apexyard#1164
- Regression successor: me2resh/apexyard#1165
- Sibling contracts: [AgDR-0124](AgDR-0124-universal-evidence-grounding-contract.md) (evidence grounding), [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md) (template overrides)

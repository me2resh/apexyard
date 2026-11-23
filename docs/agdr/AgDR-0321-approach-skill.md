# AgDR-0321: Size the technical approach to the change

## Context

GH-2149 requests a guided design for Heavy changes and a short approach record for Standard changes.
The tested draft created a Standard design file. That file could trigger architecture review through gate 3b.
The architecture vision describes long-term direction. Each Heavy change still needs a design grounded in current code.

## Decision

Add `/approach` for Heavy changes only. The Tech Lead authors the design.
The Solution Architect reviews the unchanged design through `/design-review`.
Write designs at `docs/technical-designs/<ticket>-<slug>-technical-design.md` so gate 3b recognizes them.
Send resolved key decisions to `/decide`. Keep decisions that require absent owners in Open questions.

Standard changes use an optional PR-body Approach section with Delta, Decisions, and Verification.
That section creates no file and adds no gate. Lean changes need no design document.
Use the existing ceremony tiers and preserve their safety rails.

Use Mermaid flowcharts with subgraphs for every view. Reuse the existing Mermaid lint.
Load the framework writing rule first and apply its checklist last.
Mark unread sources as `not checked`. Protect work that belongs to another ticket.

## Alternatives considered

- Use the draft's Standard document. Rejected because it adds ceremony and can trigger an existing gate.
- Extend only the architecture vision. Rejected because it cannot describe each change's current state and delivery slices.
- Add a new design gate. Rejected because existing gates cover the required reviews.

## Consequences

Heavy changes gain a guided design grounded in project evidence.
Standard changes retain a short record inside their PR.
The skill adds interview time for Heavy changes. The first five uses record elapsed time through design approval.
Static tests check the prompt contract. They cannot prove model behavior or diagram correctness.

## Verification

Run the focused approach, writing, skill registry, ownership, tier-map, and token budget tests.
Run Markdown lint and shellcheck when available.
The ticket's supplied draft tests provide prior usage evidence. This change still needs review in its final form.

## Glossary

| Term | Definition |
|---|---|
| Approach | A design for one Heavy change or a short Standard PR section. |
| AgDR | Agent Decision Record. |
| Gate 3b | The existing architecture review gate. |

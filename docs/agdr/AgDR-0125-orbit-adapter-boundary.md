# ORBIT adapter boundary in ApexYard

> In the context of adding an opt-in ORBIT skill to ApexYard, facing a portable planning standard with its own CLI and lifecycle, I decided to keep the adapter thin and project-local to achieve governed adoption without coupling ORBIT to ApexYard, accepting that operators must install the ORBIT CLI separately.

## Context

- ORBIT owns record schemas, lifecycle commands, validation, and repository provenance.
- ApexYard owns project resolution, ticket-first editing, AgDRs, review, QA, and deployment gates.
- Managed projects may define custom `workspace:` paths in the portfolio registry.
- The first integration is an opt-in skill and must not change existing planning behavior.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Embed ORBIT lifecycle logic in ApexYard | One integrated command surface | Duplicates the standard and couples it to one framework |
| Make ORBIT call ApexYard hooks and trackers | Centralized governance | Makes the portable standard depend on ApexYard internals |
| Thin ApexYard adapter around the ORBIT CLI | Preserves ownership boundaries and enables opt-in adoption | Requires separate CLI installation and adapter maintenance |

## Decision

Chosen: **thin, opt-in ApexYard adapter**, because ORBIT must remain usable by other harnesses while ApexYard retains responsibility for its governance gates.

The adapter resolves the selected project from the portfolio registry, honors its configured workspace path, stores records under that project's `docs/orbit/`, and invokes the portable CLI. It does not create external tracker records, change source code, or execute slices.

## Consequences

- Existing ApexYard planning skills remain unchanged.
- ORBIT records stay with the managed project that owns them.
- Custom registry workspace paths are supported.
- Operators must install or configure the ORBIT CLI before using the skill.

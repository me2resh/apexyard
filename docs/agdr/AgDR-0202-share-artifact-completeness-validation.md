# Share artifact completeness validation

> In the context of review and PR creation, facing missing artifact sections, I decided to share the existing local validator across artifact profiles, accepting that it checks structure rather than meaning.

## Status

Accepted

## Context

AgDR-0161 added a local Rex review body check before the Rex marker write. PR creation checks two configurable headings. Tariq's review template relies on instructions alone. An incomplete review or PR can lose the evidence that a reader needs.

The maintainer split issue #1343. The review triage half depends on a promotion from #1341. That spike was discarded. This decision covers deterministic artifact completeness only.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add separate checks to each producer | Small local edits | Rules drift across artifacts |
| Extend the AgDR-0161 local validator with profiles | One place for required structure | Each producer must call it |
| Change merge gates to inspect posted bodies | Gate sees host state | Changes the marker contract and host dependency |

## Decision

Chosen: **extend the AgDR-0161 validator with artifact profiles**, because the existing local check already serves the review flow. It checks Rex, Tariq, PR, and AgDR structure. PR creation calls it when a body is supplied. Tariq calls it before posting. The decision skill calls it after writing an AgDR.

The PR profile requires Summary, Testing, Glossary, and a Closes or Refs line. Project configuration can add headings. A skip marker does not override these fixed requirements. Review profiles require their template headings and a Reviewed commit footer. The AgDR profile requires a title and the template's main sections.

The validator reports a local complete or incomplete result. It does not inspect prose quality or the posted host body. It does not select review depth or write a marker. The existing Rex helper remains the only approval marker writer in this change. No merge gate changes.

## Consequences

- Incomplete local bodies fail their producer check before publication or decision reporting.
- PR creation with a supplied unreadable body fails without claiming that its sections are absent.
- PR creation with `--fill` has no local body to inspect. The hook cannot validate that generated body before creation.
- Review triage, provider confidence, and provider fallback remain deferred after #1341 was discarded.
- Heading presence does not prove substantive evidence. Human review still judges the content.

## Artifacts

- Issue: #1343
- Related: AgDR-0161
- Files: `.claude/hooks/_lib-review-markers.sh`, `.claude/hooks/validate-pr-create.sh`, `.claude/agents/solution-architect.md`, `.claude/skills/decide/SKILL.md`

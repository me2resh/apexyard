# AgDR-0317: Mark back-filled decisions in the existing template

## Context

Ticket #2123 needs short records for choices made before the team kept decision records.
An Agent Decision Record (AgDR) must distinguish remembered reasons from evidence of an earlier comparison.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Separate template | Isolates the short form | Duplicates template sections and adopter overrides |
| Optional recording field | Reuses the existing template | Requires conditional instructions |

## Decision

Use an optional `recording: back-filled` field because one template preserves existing overrides with fewer changes.
Keep the original choice date separate from the timestamp that records when the team wrote the record.
Count marked records separately without adding a category.

## Consequences

Remembered reasons, known limits, and change triggers form the short record.
The options section states uncertainty unless the person confirms an earlier comparison.
A small shell helper counts explicit markers in closed frontmatter blocks.
Existing records remain valid without the new field.

## Artifacts

- Ticket: https://github.com/me2resh/apexyard/issues/2123
- Template: `templates/agdr.md`
- Skills: `/decide` and `/agdr`

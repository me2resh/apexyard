---
id: AgDR-0309
timestamp: 2026-11-21T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: n/a
trigger: user-prompt
status: executed
category: patterns
---

# Reliability checklist item format and loader

> In the context of Rex needing a short list of past-incident checks that match a diff, facing a handbook system that selects by path only, I decided to add a machine-read item format and a loader script with a second discovery path, to achieve a small and exact checklist per review, accepting that adopters must follow a strict item format.

## Context

- Issue me2resh/apexyard#2092 asks for a checklist of items with a trigger, a check, and a source.
- Rex must load only the items whose trigger matches the diff.
- Handbook discovery (code-reviewer section 8) selects whole files by path convention.
- AgDR-0037 adds `paths:` front matter for domain handbooks. It selects whole files by path glob only.
- A trigger on added or removed lines needs a content match. A path glob cannot express it.
- Adopters must add items without editing the framework file.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) Extend the `paths:` front matter of AgDR-0037 | One mechanism. | It selects files, not items. It has no content match. A file with five items loads in full. |
| (b) Prose items that Rex reads in full | No new code. | Rex loads every item on every review. Selection depends on model judgement. |
| (c) A strict item format and a loader script | Exact selection. Testable. Both handbook layers work. | A second discovery path. Adopters must follow the format. |

## Decision

Chosen: **(c)**.

- Each item is a heading plus three plain lines: `Trigger:`, `Check:`, `Source:`.
- A trigger is `path:` (a shell glob on changed paths) or `regex:` (a Python regular expression on added and removed lines).
- Files named `architecture/reliability-*.md` in the public layer and the private layer hold items.
- `.claude/skills/code-review/reliability-triggers.sh` reads a unified diff and prints only matched items.
- The loader finds the ops root from its own location and warns when the private layer is missing.
- The loader stops with an error for a malformed item. It never drops an item without notice.
- Rex skips `reliability-*.md` in section 8 discovery and uses the loader instead.
- Enforcement follows the handbook convention. Seed items are advisory.

## Consequences

- Reviews load a small list that matches the diff.
- A malformed adopter file fails loudly, and Rex reports it as Unverified.
- Seed triggers are narrow. A check against 150 recent framework commits matched 7 of them.
- The loader is a second discovery path. Section 8 and AgDR-0037 stay unchanged for other handbooks.
- A change to the item format needs a new AgDR, because adopters write files against it.

## Artifacts

- `handbooks/architecture/reliability-checklist.md`
- `.claude/skills/code-review/reliability-triggers.sh`
- `.claude/skills/code-review/reliability_triggers.py`
- `.claude/skills/code-review/tests/test_reliability_triggers.py`

---
id: AgDR-0273
timestamp: 2026-10-24T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Handbook front matter, generated indexes and rule tests

> In the context of handbooks with no owner and no review date, facing rules that nobody owns or rechecks, I decided to add a front matter schema, a migration script, generated folder indexes and rule tests to achieve owned and dated rules, accepting a small set of `bin/kb-*` scripts to maintain.

## Context

Rex reads handbooks as plain prose. A reader cannot tell who owns a rule or when someone last checked it. Ticket #1877 asks for owners and review dates on handbooks and rules. The work ships in three steps. This record covers all three.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Front matter in each handbook file | Metadata stays next to the rule. Git history gives safe defaults. | Needs a migration for old files. |
| One central registry file | One place to read | Drifts from the rule files. Merge conflicts. |
| A database | Fast queries | New dependency. Adopters must run a service. |

## Decision

Chosen: **front matter in each handbook file**, because it needs no new dependency and keeps the source of truth in the rule file.

- **Front matter fields (step 1 of 3):** `owner`, `verified_by`, `verified_on`, `stale_after`, `sources`, `version`, `status`. A missing field defaults from git: the author and date of the last commit. `stale_after` defaults to `verified_on` plus 180 days. `bin/kb-migrate` adds missing fields, keeps every existing key, and works only inside `handbooks/`. A second run changes nothing.
- **Generated indexes (step 2 of 3):** `bin/kb-index` writes an `index.md` per handbooks folder. The `--check` flag reports drift.
- **Rule tests (step 3 of 3):** `/codify-rule` writes a test case under `rule-tests/`. Rex findings carry `rule-id:`.

## Consequences

- An adopter who does not run these scripts sees no change. No hook and no `settings.json` entry changes.
- Handbooks may start with a front matter block. `ENFORCEMENT: blocking` is then the first line after the block.

## Artifacts

- Ticket: #1877
- Files: `bin/kb-migrate`, `bin/kb-index`, `bin/_lib-kb.sh`, `docs/knowledge-base.md`, `rule-tests/README.md`

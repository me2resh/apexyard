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

# Knowledge base: front matter, compile output and freshness check

> In the context of handbooks, rules, AgDRs and ORBIT records with no owner and no review date, facing rules that nobody owns or rechecks, I decided to add a front matter schema, a read-only compile step and a nightly freshness check to achieve owned and dated rules, accepting a new set of `bin/kb-*` scripts to maintain.

## Context

Rex reads handbooks and rules as plain prose. A reader cannot tell who owns a rule or when someone last checked it. Ticket #1877 asks for a versioned knowledge base. The work ships in four steps. This record covers all four.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Front matter in each source file, compiled into `kb/` JSON | Metadata stays next to the rule. Sources are never edited by the compile. Output is easy to diff. | Needs a migration for old files. |
| One central registry file | One place to read | Drifts from the rule files. Merge conflicts. |
| Compile into a database | Fast queries | New dependency. Adopters must run a service. |

## Decision

Chosen: **front matter in each source file, compiled into `kb/` JSON**, because it needs no new dependency and keeps the source of truth in the rule file.

- **Front matter fields:** `owner`, `verified_by`, `verified_on`, `stale_after`, `sources`, `version`, `status`. A missing field defaults from git: the author and date of the last commit. `stale_after` defaults to `verified_on` plus 180 days.
- **Migration (step 1):** `bin/kb-migrate` adds missing fields and keeps every existing key. A second run changes nothing. `bin/kb-index` writes a generated `index.md` per handbooks folder.
- **Compile (step 2):** `bin/kb-compile` writes one JSON file per entry and `kb/manifest.json` with a SHA-256 content hash. Output has no timestamp, so a second run gives the same bytes. The compile never edits a source file. `kb/` is gitignored.
- **Network guard (step 2):** the compile makes no network call. It pushes the manifest only when `--push` is set and both `APEXYARD_TOKEN` and `APEXYARD_KB_ENDPOINT` are set.
- **Freshness (step 3):** `bin/kb-freshness` lists entries past `stale_after`. The workflow `.github/workflows/kb.yml` runs the compile on push and the check nightly. It keeps one open PR for stale entries.
- **Rule tests (step 4):** `/codify-rule` writes a test case under `rule-tests/`. Rex findings carry `rule-id:`.

## Consequences

- An adopter who does not run the workflow sees no change. No hook and no `settings.json` entry changes.
- Handbooks may start with a front matter block. `ENFORCEMENT: blocking` is then the first line after the block.
- AgDR and ORBIT records get `stale_after: null`, so they never go stale.
- The scripts need `jq`, which the hooks already need.

## Artifacts

- Ticket: #1877
- Files: `bin/kb-migrate`, `bin/kb-index`, `bin/kb-compile`, `bin/kb-freshness`, `bin/_lib-kb.sh`, `.github/workflows/kb.yml`, `docs/knowledge-base.md`

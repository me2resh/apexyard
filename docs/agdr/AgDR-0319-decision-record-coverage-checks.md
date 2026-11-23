# AgDR-0319: Check decision record coverage with small shell scripts

## Context

Ticket #2124 needs two reports. `/handover` must show which dependencies and outside hosts lack an Agent Decision Record (AgDR). `/agdr stats` must show proposed or superseded AgDRs that code still uses, and runtime dependencies that only tests import.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Shell scripts under `.claude/skills/agdr/scripts/` | Follows `count-backfilled.sh`. Keeps SKILL.md short. Testable on a fixture | Name matching is simple text matching |
| Instructions in SKILL.md only | No new files | Breaks the skill byte caps. Not testable |
| Language-aware import parsing | Fewer false matches | Large per-language cost |

## Decision

Use shell scripts, because they keep both skills under the byte caps and tests can run them on a fixture repository.
Match names as whole words, case-insensitive. Ignore names of 3 characters or fewer.
The scripts give a hint only. A person classifies each row as choice recorded, usage recorded only, or not named.

## Consequences

Python import names that differ from package names can be missed.
Short names such as `zod` are never reported.
Package registry hosts are not listed as outside hosts.

## Artifacts

- Ticket: https://github.com/me2resh/apexyard/issues/2124
- Scripts: `.claude/skills/agdr/scripts/`, `.claude/skills/handover/scripts/coverage.sh`
- Test: `.claude/hooks/tests/test_agdr_coverage.sh`

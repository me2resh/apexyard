# AgDR-0320: Check new dependencies with a script and a Rex item

## Context

Ticket #2122 needs a check that a PR adding a runtime dependency or outside host links an AgDR or a stack-register line.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Script plus a Rex checklist item | Small. Rex and CI can run it. Reuses `list-subjects.sh` | Not enforced before a push |
| New PreToolUse hook | Blocks early | Adds a gate that can misfire. Gates are guardrails (AgDR-0267) |

## Decision

Add `.claude/skills/agdr/scripts/check-dependency-record.sh`. It compares subjects at the base ref and at HEAD. Rex runs it in review check 7.
A new runtime dependency or outside host with no record blocks. A new dev-only dependency warns.
A record is a whole-word mention in `docs/agdr/*.md` or `docs/stack-register.md`. Names of 3 characters or fewer are ignored.

## Consequences

No existing gate changes. A name written in another form can need a manual check.

## Artifacts

- Ticket: https://github.com/me2resh/apexyard/issues/2122
- Test: `.claude/hooks/tests/test_dependency_record_link.sh`

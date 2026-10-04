# AgDR-0217: Require a merged ORBIT slice before Feature and Task issues

> For issue #1565, I chose a project-scoped ticket creation gate so each ORBIT Feature or Task issue points to a durable slice record before work starts.

## Context

ORBIT planning orders work as goal, reconciliation, slice, issue, then PR.
Without a gate, an agent can file an issue before the slice record exists.
That breaks the link used by progress views and later reconciliations.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Skill instruction only | Small change. | Raw ticket creation can skip the record. |
| PreToolUse guard with default-branch read | Checks the durable record before filing. | Requires a local checkout and updated remote ref. |
| Working-tree file check | Allows immediate filing. | An unmerged record can disappear or change. |

## Decision

Chosen: **PreToolUse guard with a default-branch read**. When the target
project enables `orbit.default_planning`, Feature and Task issues must carry
`ORBIT slice: <id>` and the matching `docs/orbit/slices/<id>.json` must exist
on the project's local default-branch remote ref. The slice ID is restricted
to lowercase, hyphen-separated `slice-` identifiers before it enters a Git
object path. The record PR must merge before the issue is filed.

The explicit escape hatch is `ORBIT slice: none — <reason>`. The hook accepts
an ASCII dash or double dash too, requires a non-empty reason, and logs it to
stderr. This records why a ticket bypassed the normal planning order.

The gate fails closed with exit 2 when ORBIT is on and it cannot read the
ticket body, the default-branch ref, or the named record. It does not block
Bug or Spike issues or projects with ORBIT off. `/start-ticket` warns about
a missing slice line but still starts the ticket.

## Consequences

- `/orbit slice` saves a record named after its ID and files its issue after
  the record merges, using the existing GitHub adapter preview and preflight.
- A stale local default-branch ref can block a valid issue until it is updated.
- The command-text hook covers recognized creation calls. It is an agent
  workflow gate, not a server-side issue policy.

## Artifacts

- Issue #1565
- `.claude/hooks/require-orbit-slice-for-ticket.sh`
- `.claude/skills/orbit/SKILL.md`
- `.claude/hooks/tests/test_require_orbit_slice_for_ticket.sh`

# AgDR-0221: Warn when an unfinished ORBIT outcome has no slice

> For issue #1570, I chose an adapter warning for local ORBIT records. The ORBIT CLI must own its validation and progress views.

## Context

The ORBIT Plan lists outcomes and acceptance criteria. The Reconciliation
records each criterion's status. A slice lists the Plan references it advances
in `contributesTo`.

Teams create slices as work becomes ready. An unfinished outcome can therefore
have no slice. The current adapter does not report that gap.

The ApexYard repository contains the `/orbit` skill and its local helpers.
The external `orbit-spec` CLI owns `orbit reconcile`, `orbit validate`,
`PROGRESS.md`, and the status pane. AgDR-0164 keeps that boundary.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Change only the skill text | Small edit. | Agents must detect every gap manually. |
| Add an adapter helper after CLI operations | Gives local warnings now. | Other CLI users do not receive them. |
| Generate progress files in the adapter | Changes the requested view here. | Duplicates CLI output and its ownership. |

## Decision

Chosen: **add an adapter helper after successful CLI operations**. It reads
the selected Plan, matching Reconciliation, and local slice records. It emits
one warning per outcome with an unachieved criterion and no covering slice.

The Plan has no criterion status field. The helper reads
`criterionAssessments[].status` from the Reconciliation. Only `achieved`
counts as met. A missing assessment does not establish achievement. A slice
covers an outcome when its `contributesTo` list names that outcome ID or one
of its criterion IDs. A string `contributesTo` is one exact ID, not a
substring search. The slice must match the Plan ID and revision.

For `orbit validate`, the helper checks only the highest `revision` in each
Plan ID's record set. It reads each Plan record's `revision` field, not its
filename. Equal highest revisions select the last filename in lexical order.
The helper reports the tie on stderr. For `orbit reconcile`, it checks the
specified Plan revision. Every coverage warning names its Plan ID and revision.

When several Reconciliations match a Plan ID and revision, the helper selects
the latest `reconciledAt` instant. It converts `Z` and timezone-offset
timestamps to UTC seconds, then compares fractional seconds. Equal instants
select the last filename in lexical order and produce a tie diagnostic on
stderr. Records without a usable timestamp rank below timestamped records and
use filename order among themselves. The selected record still receives the
coverage check.

The helper skips each malformed slice file with one stderr diagnostic naming
the file. It still checks the Plan with the remaining slices. An unreadable
Plan or Reconciliation has a diagnostic and no coverage warnings. The helper
always exits zero.
The adapter reports CLI failures separately and preserves the CLI exit status.

The skill also defines slice IDs as existing only with a slice record. Agents
must create a record when planning work and must not reserve IDs in prose.

## Consequences

- `/orbit reconcile` and `/orbit validate` can report uncovered outcomes after successful CLI calls.
- Warnings do not block planning or validation.
- The adapter does not change ORBIT schemas or generate `PROGRESS.md`.
- The `orbit-spec` CLI still needs four changes: detect uncovered outcomes from
  Plan, Reconciliation, and slice records; warn during `orbit reconcile` and
  `orbit validate` without changing exit status; mark them `no slice` in
  `PROGRESS.md`; and mark them `no slice` in the status pane.

## Artifacts

- `.claude/skills/orbit/lib/warn-uncovered-outcomes.sh`
- `.claude/skills/orbit/SKILL.md`
- `.claude/skills/orbit/tests/test_uncovered_outcomes.sh`
- `docs/orbit-adapter.md`

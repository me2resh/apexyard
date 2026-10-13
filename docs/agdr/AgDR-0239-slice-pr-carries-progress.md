# Slice PR carries progress

Status: proposed.

## Context

The ORBIT pane reads Reconciliation records on dev.
A separate records PR delays progress after a slice build PR merges.
AgDR-0225 option I puts status changes in a cycle PR.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep option I | One records PR per cycle | Progress waits for that PR |
| Amend option I | Progress appears at slice merge | Concurrent records can restore old statuses |

## Decision

Amend AgDR-0225 option I.
A slice build PR may carry a Reconciliation for its contributesTo criteria.
The build agent must cite changed PR paths before it raises a status.
A merge alone changes no status.

The ac8-9 check compares the candidate with the newest Reconciliation on dev.
It rejects status changes outside contributesTo with exit 17.
CI repeats this check after each branch update.
This guard prevents a concurrent slice PR from restoring an old status outside its scope.

A snapshot commit can disappear after a squash merge.
The ac8-10 fix records the dev merge-base and PR number in an observation.
The lint checks both values with exit 19.
The status command finds the squash commit through its PR number suffix.

## Consequences

A slice PR without a Reconciliation produces a warning.
Plan revisions keep the records PR flow. Revision 5 permits one proposed slice in a slice PR.
A slice PR with a Reconciliation does not count as a records PR for ac8-5.
No merge gate reads ORBIT records, as Build with ORBIT ac2-4 requires.
Rex reviews the Reconciliation in the PR diff.

## Artifacts

- Ticket: me2resh/apexyard#1713.
- Prior decision: AgDR-0225.
- Scope test: test_records_lint_slice_scope.sh.
- Squash test: test_status_live_squash_commit.sh.

## Revision 5

The last slice PR step proposes one next slice from the Plan order and its Reconciliation.
Naqid challenges the proposal. The owner confirms its scope in PR review, before merge.
A basedOn-only change needs no new confirmation. A scope change does.
When every outcome is achieved, the PR states that no next slice remains.

The C6 guard rejects an outcome with an unfiled slice on the base branch.
An exact slice ID token in an open or closed ticket counts as filed.
The PR's own slice counts as delivered at merge.
CI supplies ticket IDs and repeats the lint after branch updates.

A no at handoff marks the proposal withdrawn in the next Plan notes update.
The guard ignores IDs under `## Withdrawn slices` with a `- Withdrawn: <slice-id>` line.
Handoff checks the merged PR base branch. The ticket guard also accepts the configured integration branch, with dev as its fallback.

`refresh-slice-record.sh` refreshes merge-base observations and the Snapshot after each branch update.
It preserves criterion statuses and slice scope. It updates proposal provenance when needed.

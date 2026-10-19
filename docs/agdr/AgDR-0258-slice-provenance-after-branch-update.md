---
id: AgDR-0258
timestamp: 2026-10-19T14:30:00Z
agent: platform-engineer (Adel)
model: composer
session: n/a
trigger: user-prompt
status: executed
category: patterns
---

# AgDR-0258: Slice provenance after a branch update

> In the context of ready slice PRs that go red when `dev` moves, facing an exact merge-base match in `slice-pr-lint.sh`, I decided to accept an ancestor recorded merge-base when status-dependent records did not change, to keep approved slice PRs green after refresh, accepting that the lint must fail closed when ancestry or the record diff cannot run.

## Context

`refresh-ready-prs.yml` updates every open PR labelled `ready-to-merge` when `dev` moves. A slice PR records the `dev` merge-base in its Reconciliation observation. After the update, the current merge-base `M` advances. The recorded value `R` stays on the old tip. AgDR-0239 required an exact match, so `records-lint` exited 19 with no author change.

Ticket: me2resh/apexyard#1801.
Prior decision: [AgDR-0239](AgDR-0239-slice-pr-carries-progress.md).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| 1. Accept ancestor `R` when plan records between `R` and `M` did not change | Keeps statuses honest. Covers refresh and manual branch updates. No CI write path | Extra ancestry and diff checks in the lint |
| 2. Skip slice PRs in the refresh workflow | Stops one cause of drift | A manual update still moves `M`. Ready slice PRs stay behind `dev` |
| 3. Refresh workflow runs `refresh-slice-record.sh` and commits | Records always match `M` | Adds a write path to CI. Needs bot push rights and conflict handling |

## Decision

Chosen: **option 1**.

The provenance check accepts recorded merge-base `R` when all of these hold:

1. `R` is an ancestor of the current `dev` merge-base `M`.
2. `R` is an ancestor of the PR head.
3. Between `R` and `M`, `dev` changed none of these paths: the Plan and Plan notes of the slice plan, the slice record, and every Reconciliation of that plan.

The check does not include Snapshots, `docs/orbit/history/` files, or other slice records of the same plan. Statuses live only in Reconciliations. A changed Snapshot reaches `dev` with a changed Reconciliation of the plan, which the check catches. A Plan revision also changes the Plan file. Another slice record of the plan does not change a status; including it would turn every open slice PR of the plan red when a records PR cuts a slice. Dev code that is not a record can change between `R` and `M`; the Snapshot still names the commit it observed. `refresh-slice-record.sh` also keeps every status when it moves the stamp to `M`, so the earlier flow did not reconcile code changes again either.

When `R` equals `M`, behaviour matches AgDR-0239. When `R` is not `M` and the checks pass, the lint prints one NOTE that names `R` and `M`. A non-ancestor `R` still exits 19 with "The merge-base SHA does not match." A plan-record change between `R` and `M` exits 19 with a message that lists the changed paths and names `refresh-slice-record.sh`. Ancestry or diff failures exit 19 (fail closed).

Option 2 does not fix a manual branch update. Option 3 adds a CI write path. Option 1 treats both update paths the same and keeps record-derived statuses true when `dev` did not touch the plan records.

## Consequences

- An approved slice PR can stay green after refresh when `dev` only moved unrelated files.
- When `dev` changes this plan's own records between `R` and `M`, the lint still exits 19. The operator must run `refresh-slice-record.sh` and copy the new statuses again. Two concurrent slice PRs of one plan reach this case, as #1791 and #1797 did.
- A wrong merge-base that is not an ancestor still fails with exit 19.
- Operators may still run `refresh-slice-record.sh` to rewrite observations and Snapshots. That path stays available.
- `test_refresh_slice_record.sh` no longer expects exit 19 from provenance alone after an unrelated base move.

## Architecture evolution

### Before

Slice PR provenance required the recorded merge-base SHA to equal `git merge-base <base> HEAD`. A branch update that only advanced `dev` made `records-lint` exit 19 until someone rewrote the observation. Concurrent slice PRs of one plan (#1791 / #1797) also exited 19 when the first merge changed plan records, which was correct but shared the same exact-match message.

### After

The lint still requires a single `Slice PR: #N; dev merge-base <sha>.` observation. Equality still passes. An older ancestor `R` also passes when HEAD and `M` contain `R` and no status-dependent plan record changed between `R` and `M`. A plan-record change between `R` and `M` fails with its own message that lists paths and names `refresh-slice-record.sh`. Snapshots, history files, and sibling slice records stay out of the diff so the check tracks status claims without falsely reding open slices. Dev code between `R` and `M` is not re-reconciled, matching `refresh-slice-record.sh`. The lint fails closed when it cannot prove ancestry or the record diff. The fail-before regression test pins the pre-change lint commit so post-merge runs stay stable.

### 2026-10-19 — Manual refresh only (#1814, AgDR-0259)

`refresh-ready-prs.yml` no longer runs on every push to `dev`. It runs on `workflow_dispatch` only. Branch updates that advance the merge-base still need the ancestor provenance rule above. Operators update a behind PR with `gh pr update-branch` or a manual refresh run. See [AgDR-0259](AgDR-0259-no-macos-ci-runners.md).

## Artifacts

- Issue: me2resh/apexyard#1801
- Lint: `.claude/skills/orbit/lib/slice-pr-lint.sh` (`slice_pr_merge_base_ok`)
- Tests: `.claude/skills/orbit/tests/test_records_lint_slice_merge_base_drift.sh`
- Related: [AgDR-0239](AgDR-0239-slice-pr-carries-progress.md)

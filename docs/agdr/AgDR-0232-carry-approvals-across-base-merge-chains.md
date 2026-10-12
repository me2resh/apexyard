# Carry approvals across verified base-merge chains

> In the context of automatic refreshes, facing repeated reviews, I decided to accept verified base-merge chains, accepting a limit of 10 steps.

## Context

Carry-over means that an existing approval remains valid after a base merge.
The forge is the remote service that supplies commit parents, trees, and the base branch tip.
The refresh-ready-prs workflow (#1679) can add a second base merge immediately after a manual refresh.
On 2026-10-12, PRs #1667, #1672, and #1675 lost carry-over and needed extra Rex passes.
[AgDR-0178](AgDR-0178-cheaper-merge-refresh.md) limited carry-over to one base merge.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the single-merge rule | Keep the existing limit. | Repeat reviews after automatic refreshes. |
| Accept up to 10 verified base merges | Preserve approvals after repeated clean refreshes. | Verify each step and allow more forge reads. |

## Decision

Chosen: **accept up to 10 verified base merges**, because automatic refreshes can repeat without adding unreviewed changes.
`rex_approval_carries_over` follows the first-parent chain from the head to the reviewed SHA (commit identifier).
Each step must pass all these checks:

- The forge reports exactly two parents.
- Parent[1] is an ancestor of the forge-resolved base branch tip.
- An isolated `git merge-tree --write-tree` of both parents produces the forge-reported tree.

Each ancestry and tree check uses an empty `GIT_DIR` with object alternates.
The function returns `true` only when a verified step reaches the reviewed SHA through parent[0].
The function accepts at most 10 steps.
Any failure returns a value other than `true`.

### Owner decision, 2026-10-12

The CEO approved the same rule for the CEO merge-approval marker on 2026-10-12.
Both the Rex marker and the CEO marker call the same function.
An owner approval therefore survives up to 10 verified automatic refreshes.
The original owner approval must still name the PR.

### Amendment to AgDR-0178

For chains, this record supersedes the sentence "Parent[0] is exactly the SHA the marker names" in AgDR-0178.
Instead, each verified parent[0] leads to the next step until the chain reaches the marker SHA.
This record also extends the owner decision in AgDR-0178 to the same 10-step limit.

## Consequences

- Repeated clean refreshes preserve Rex and CEO approvals without another review or owner message.
- Each check makes up to 11 forge API reads: one base-tip read and up to 10 commit reads.
- Missing objects can require additional fetches. API or git failures cannot retain approval.
- The function rejects chains longer than 10 steps. These chains need new approvals.

### Threat analysis

| Threat | Control |
|--------|---------|
| Evil merge with added content | The isolated tree check rejects a tree mismatch at any step. |
| Off-base second parent | The ancestry check rejects parent[1] outside the base history at any step. |
| Octopus merge with three or more parents | The forge parent-count check rejects it at any step. |
| Conflict or tree mismatch | The isolated merge-tree check rejects it at any step. |
| Excessive chain | The 10-step cap rejects a longer chain. |

## Artifacts

- [AgDR-0178](AgDR-0178-cheaper-merge-refresh.md).
- [Ticket #1682](https://github.com/me2resh/apexyard/issues/1682).
- [PR #1683](https://github.com/me2resh/apexyard/pull/1683).
- `.claude/hooks/_lib-merge-behind.sh`: shared carry-over function.
- `.claude/rules/pr-workflow.md`: Rex and CEO carry-over rules.
- `.claude/hooks/tests/test_lib_merge_behind.sh`: middle-step ancestry and octopus tests.

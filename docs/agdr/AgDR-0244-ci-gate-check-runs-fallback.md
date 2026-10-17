---
id: AgDR-0244
timestamp: 2026-10-17T00:00:00Z
agent: cursor
model: n/a
session: n/a
trigger: user-prompt
status: executed
category: integrations
---

# AgDR-0244: Read commit checks when gh pr checks fails

> `block-merge-on-red-ci.sh` blocked a pull request when `gh pr checks` printed a JSON error. Some gh builds do that on a repository with no checks. The gate now reads commit check-runs and the combined commit status before it blocks. A real fail row and a real pending row stay on the existing red path.

## Context

The GitHub path allows three results from `gh pr checks`. Exit 0 means the checks passed. The exact no-checks line means the repository may have no CI. Every other non-zero exit blocks as red CI.

gh 2.96.0 and gh 2.102.0 do not follow that contract on a repository with zero checks. `gh pr checks` exits 1. The text is `invalid character '{' looking for beginning of object key string`. It is not the no-checks line. The gate then reports red CI.

Check-runs and legacy commit statuses are the authoritative commit APIs. CI can report through statuses and omit check-runs. AgDR-0212 and AgDR-0213 stay in force for a real check table and for Actions run failures.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the red block for every non-zero exit | No new API calls | Blocks a repository that has no CI when gh prints a parse error |
| Treat every non-zero exit as no checks | Removes the false block | Hides a real failure when the CLI text is unexpected |
| Read check-runs and combined status only when the text is not a check table | Uses the commit APIs. Keeps real fail and pending rows on the red path | Adds two API calls on the error path. An API failure must stay fail-closed |

## Decision

Chosen: **read check-runs and the combined status** when `gh pr checks` exits non-zero and the text is not a recognised check table.

Call `gh api --paginate` with `per_page=100` for both endpoints. GitHub repeats `total_count` on every page. Accept that value when the collected row count equals it. Accept the sum of the page totals when the collected row count equals that sum. Block when the count matches neither value.

Allow when both totals are 0. Print one note that the fallback ran. Allow when every check-run is completed with `success`, `neutral`, or `skipped`, and the combined state is `success` or there are no statuses. Block when a run is not completed, or its conclusion is outside those three values. Block when the combined state is `failure`, `error`, or `pending` and the status total is greater than 0. List the rows.

Block when either API call fails, the JSON is invalid, or the repository or head SHA is missing. Do not call this path for a fail row or a pending row.

## Consequences

- A gh parse error on a repository with no checks allows the merge. The note names the fallback.
- A failed, pending, or incomplete commit result still blocks.
- An API failure on this path blocks. Actions run failures stay fail-open under AgDR-0213 when `gh pr checks` itself returned a real result.
- A real red table and a real pending table keep the existing red-CI message.

## Architecture evolution

### Before

The GitHub merge gate trusted `gh pr checks` for the final verdict. Exit 0 allowed the merge after the Actions head-run check. The exact no-checks line allowed a repository with no CI. Any other non-zero exit blocked as red CI. A JSON parse error from gh used that last branch.

### After

The same three results still use those branches. An unreadable `gh pr checks` result is not a CI verdict. The gate reads commit check-runs and the combined commit status for the pull request head. Both totals of 0 allow the merge. A bad or unreadable commit result blocks it.

## Artifacts

- Issue: me2resh/apexyard#1736
- Related: [AgDR-0212](AgDR-0212-gated-ci-blocks-the-merge.md), [AgDR-0213](AgDR-0213-head-runs-on-every-merge.md)
- Hook: `.claude/hooks/block-merge-on-red-ci.sh`
- Tests: `.claude/hooks/tests/test_block_merge_on_red_ci.sh`

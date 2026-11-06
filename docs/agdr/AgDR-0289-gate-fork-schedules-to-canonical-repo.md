---
id: AgDR-0289
timestamp: 2026-11-06T19:53:32Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# Run the conformance and tests schedules only in the canonical repo

> In the context of `conformance.yml` and `tests.yml` running their daily `schedule` triggers in every adopter fork, facing daily failed Conformance runs, Actions minutes spent in forks, and a badge job that commits into the fork, we decided to gate only the `schedule` event of those two workflows to `me2resh/apexyard`, to achieve quiet forks that still run CI on their own pull requests and pushes, accepting that an adopter who wants the nightly runs in a fork must edit the guard.

## Context

- `codeql.yml` and `scorecard.yml` already run only in `me2resh/apexyard`, through a job-level `if: github.repository == 'me2resh/apexyard'` (AgDR-0096, #1370).
- `conformance.yml` (cron `17 6 * * *`) and `tests.yml` (cron `17 3 * * *`) have no guard, so their schedules also run in every fork.
- In a fork, the `badge` job commits badge JSON to an orphan `conformance-badge` branch, and `nightly-failure` can open a "Nightly CI failed" issue in the fork's own tracker.
- On one adopter fork, 20 of 26 runs were scheduled, and all 9 scheduled Conformance runs failed. GitHub then paused Actions on that fork, which also stopped its PR CI. It is not verified that the schedules caused the pause (#1981).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Gate only the `schedule` event: `github.event_name != 'schedule' \|\| github.repository == 'me2resh/apexyard'` on the jobs that a schedule starts | Forks keep `pull_request`, `push`, `workflow_call` and `workflow_dispatch` runs, and the red-CI merge gate reads those results. Upstream behaviour is unchanged. | Four job conditions change, because `badge` and `hook-test-suite` start with `always()` and need their own guard |
| Gate whole workflows to the canonical repo, as AgDR-0096 did for `scorecard.yml` | One plain condition per job | Forks lose PR CI from `tests.yml`, which their own merge gate relies on |
| Use `!github.event.repository.fork` | Reads as "not a fork" | `github.event.repository` is absent on `schedule` runs (AgDR-0096), so it cannot gate a schedule reliably |
| Keep the schedules and document how to disable them | No workflow change | Every adopter keeps paying for daily runs, failed Conformance runs, and the badge branch until they find the note |

## Decision

Chosen: **gate only the `schedule` event**, because it removes the daily runs from forks while forks keep the pull-request CI that `block-merge-on-red-ci.sh` reads. `github.repository` is set on every event, including `schedule`. The guard sits on each job that a schedule can start:

- `conformance.yml`: `conform`, and `badge`, whose `always()` would otherwise start it
- `tests.yml`: `tier`, which every other job needs, and `hook-test-suite`, whose `always()` would otherwise start it

## Consequences

- A fork no longer runs either schedule, writes no `conformance-badge` branch, and opens no "Nightly CI failed" issue.
- `pull_request`, `push`, `workflow_call` and `workflow_dispatch` runs work in forks as before. A manual `workflow_dispatch` of `conformance.yml` still publishes the badge, as before.
- The canonical repo runs both schedules as before.
- `test_ci_tiers.sh` asserts the four conditions.
- An adopter who wants the nightly runs in a fork edits the guard to name their own repository.

## Artifacts

- me2resh/apexyard#1981
- `.github/workflows/conformance.yml`, `.github/workflows/tests.yml`, `.claude/hooks/tests/test_ci_tiers.sh`

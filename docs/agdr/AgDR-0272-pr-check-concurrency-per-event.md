---
id: AgDR-0272
timestamp: 2026-10-22T12:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# PR check concurrency group per event action

> In the context of PR Title Check and ORBIT records lint, facing duplicate runs that cancel each other on one PR head, I decided to add the event action to the concurrency group to achieve one uncancelled run per event, accepting a few extra Linux minutes.

## Context

Each new PR head starts two runs of each workflow (for example `opened` and `edited`). The concurrency group held only the PR number, so one run cancelled the other. The merge gate reads the cancelled run and refuses the merge until someone reruns it (#1856, epic #1846 G3).

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Merge gate ignores cancelled runs | No workflow change | Weakens a gate. A real cancelled run could hide a failure. |
| Per-action group (PR number and event action) | Opened, edited and synchronize do not cancel each other. A title edit still runs. Two pushes in a row still cancel the older run. | Runs of different actions execute in parallel. |
| Drop the `edited` trigger | One run per head | A title edit no longer re-runs PR Title Check. |

## Decision

Chosen: **per-action group (PR number and event action)**, because it keeps the gate strict and keeps the title re-check.

## Consequences

- An edit and a push on the same head run in parallel.
- Two pushes in a row still cancel the older run, because both use the `synchronize` action.
- Two quick title edits on one head can still give a cancelled PR Title Check run. A rerun clears it.
- Cost: a few extra Linux runner minutes. No macOS runner is added.

## Timeout

The `hook-tests` job in `.github/workflows/tests.yml` now has `timeout-minutes: 45` (was 30). Recent runs took 21 to 29 minutes. The run for PR #1850 (run 39732592843) reached 30 minutes and was cancelled. No runner or matrix entry changes.

## Artifacts

- Ticket: #1856
- Files: `.github/workflows/pr-title-check.yml`, `.github/workflows/orbit-records-lint.yml`

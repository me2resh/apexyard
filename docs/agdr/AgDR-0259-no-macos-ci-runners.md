---
id: AgDR-0259
timestamp: 2026-10-19T17:30:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: ci-1814-build
trigger: user-prompt
status: executed
category: patterns
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0259: No macOS CI runners

> In the context of Actions cost and queue pressure from macOS minutes, facing a CEO decision to stop cloud macOS jobs, I chose Linux-only hook CI with local Bash 3.2 and awk checks, accepting delayed detection of macOS-only faults.

## Context

On 2026-10-19 the repository's October Actions usage reached $728 at list price. macOS runners were about $643 of that total. The public-repository discount covered the bill, but the volume filled the CI queue and would cost money on a private fork.

The CEO decided on 2026-10-19 that ApexYard will not run macOS jobs on cloud runners again. The `/bin/bash` 3.2 and system-awk checks run locally before push.

Three multipliers drove the volume: macOS legs in `tests.yml`, automatic `refresh-ready-prs.yml` runs after every push to `dev`, and missing concurrency or job timeouts on most workflows. Ticket #1814 records the decision to remove macOS from cloud CI.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep macOS shards and affected legs | CI catches Bash 3.2 and BSD awk faults | High minute cost and long PR queues |
| Linux-only CI; local Bash 3.2 and awk before push (chosen) | Cuts macOS minutes to zero; keeps Linux coverage | A macOS-only fault can reach `dev` until a local or reviewer run finds it |
| Drop nightly Linux too | Lowest Actions use | Loses scheduled regression on `dev` |

## Decision

Chosen: **Linux-only hook CI, with local Bash 3.2 and awk before push.**

- `tests.yml` keeps Linux jq-1.7 and jq-1.8. It removes every `macos-latest` matrix entry and every macOS-only step.
- `refresh-ready-prs.yml` runs on `workflow_dispatch` only.
- Every PR-triggered workflow uses a concurrency group that cancels a superseded PR run. Release and tag workflows keep `cancel-in-progress: false`.
- Every job sets `timeout-minutes` at 30 or less.
- Contributors run `/bin/bash bin/run-hook-tests.sh` locally before push. An optional mawk run links mawk as `awk`. `test_awk_ere_interval_lock.sh` in Linux CI is the ERE guard (AgDR-0247 records that Homebrew mawk 1.3.4 accepts ERE intervals).

## Consequences

- CI no longer proves Bash 3.2 or macOS system awk on every PR.
- A behind ready PR is updated by hand (`gh pr update-branch` or a manual refresh workflow run).
- Superseded PR runs cancel, so Actions minutes track the latest commit.
- Weighted `--shard` support in `bin/run-hook-tests.sh` stays for local use. CI does not pass `--shard`.

## Architecture evolution

### Before

`tests.yml` queued macOS bash-3.2 shards on heavy runs and an affected macOS leg on light PRs. `refresh-ready-prs.yml` ran on every integration push and on PR synchronize. Most workflows lacked concurrency cancel and job timeouts.

### After

Hook CI runs on Linux only. Refresh is manual. PR workflows cancel superseded runs. Every job has a timeout of 30 minutes or less. Bash 3.2 and macOS awk stay a local pre-push duty. The optional local mawk run links mawk as `awk`. `test_awk_ere_interval_lock.sh` in Linux CI is the ERE guard.

## Artifacts

- Issue: me2resh/apexyard#1814
- Workflows: `.github/workflows/tests.yml`, `.github/workflows/refresh-ready-prs.yml`, and other `.github/workflows/*.yml`
- Docs: `CONTRIBUTING.md`, `.claude/rules/pr-workflow.md`, `golden-paths/pipelines/README.md`
- Related: [AgDR-0236](AgDR-0236-tiered-ci.md), [AgDR-0229](AgDR-0229-exact-fast-paths-and-weighted-test-shards.md)

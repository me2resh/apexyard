---
id: AgDR-0236
timestamp: 2026-10-12T16:00:00Z
agent: claude
model: claude-opus-5-5
trigger: user-prompt
status: executed
---

# AgDR-0236: Tiered CI

> In the context of scarce macOS runners, I chose tiered CI to shorten PR queues, accepting delayed detection in unaffected macOS tests.

## Context

Every PR previously queued two Linux jobs and four macOS bash-3.2 shards.
Refreshing all ready PRs multiplied those queues after each merge.
Ticket #1690 records the owner's decision to reduce regular PR work.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Full matrix on every PR | All platforms test every change | Six jobs compete for runners |
| Light PR tier with heavy integration checks | Fewer macOS jobs per PR | Unaffected macOS tests can fail after merge |

## Decision

Chosen: **light PR tier with heavy integration checks**.

- Regular PRs run the full Linux jq-1.7 suite. When the selector names specific tests, one macOS bash-3.2 job runs only those tests.
- Docs-only PRs skip hook jobs. Every changed path must be under `docs/`, or Markdown outside `.claude/`.
- Pushes to `dev` and `main`, manual runs, and nightly runs execute the full six-job matrix.
- The nightly schedule starts at 03:17 UTC and checks out `dev`.
- A failed nightly creates or updates one open `Nightly CI failed` issue with the run link.
- Release PRs execute the full matrix. They also run the reusable conformance workflow as a required leg when the repository variable `CONFORMANCE_ON_RELEASE` is `true`.
- A release PR has a `release/v*` head branch or a title that starts with `release(`.
- Release detection takes precedence over docs-only detection.
- The `hook test suite` summary requires the applicable jobs and retains its existing check name.
- Each integration push refreshes only the oldest open, non-draft, same-repository labelled PR that is behind.
- A failed refresh attempt stops the run and retains the existing comment-once guard.

The selector reads newline-separated changed paths from the PR base-to-head diff.
A changed test selects itself. A changed hook selects tests that reference its filename.
A changed test helper or fixture under a tests directory selects `ALL`.
Any other changed file selects tests that reference its full path.
The selector prints `ALL` for shared inputs:

- `.claude/hooks/_lib-*.sh`
- `.claude/settings.json` and `.claude/project-config.defaults.json`
- `bin/run-hook-tests.sh` and `bin/select-affected-tests.sh`
- `.github/workflows/tests.yml` and `.githooks/*`

`ALL` means the PR needs the full suite. On a regular PR, the full suite then runs on Linux only, and no macOS job runs. The full macOS suite takes about 32 minutes on one runner, over the 30-minute job timeout, and most framework PRs touch a shared input. Owner decision 2026-10-12: shared-input PRs wait for the merge push and the nightly run for bash-3.2 coverage. An empty selection runs no macOS tests and passes.
The runner accepts a validated, explicit test-list file through `--files`.

## Consequences

A macOS-only fault in an unaffected test, or in any test when a PR changes a shared input, can reach `dev`.
The merge push or nightly run detects that fault through the full matrix.
Linux still tests the full suite on every regular PR.
Conformance requires the `CONFORMANCE_*` secrets and fails when they are missing. On 2026-10-12 the repository has none, so `CONFORMANCE_ON_RELEASE` stays unset and release PRs skip conformance until the owner adds the secrets.
GitHub starts scheduled workflows from the default branch. The nightly checks out `dev` explicitly.
The schedule becomes active when this workflow reaches the default branch.

## Artifacts

- Ticket: #1690. Related work: #1613 and #1679.
- `.github/workflows/tests.yml` and `.github/workflows/conformance.yml`
- `bin/select-affected-tests.sh` and `bin/run-hook-tests.sh`
- `.github/workflows/refresh-ready-prs.yml` and its golden-path copy

## Glossary

| Term | Definition |
|------|------------|
| Tier | The set of CI jobs selected for an event |
| Affected test | A test selected from references to changed files |
| Conformance | Credentialed checks that prove harnesses enforce governance hooks |

## Architecture evolution

### 2026-10-19 — No macOS CI runners (#1814, AgDR-0259)

The CEO decision in #1814 removes every macOS matrix leg from `tests.yml`. Light, heavy, and release tiers stay. They now use Linux only (jq-1.7 on light PRs; jq-1.7 and jq-1.8 on heavy, release, merge, nightly, and manual runs). `refresh-ready-prs.yml` no longer runs on push or PR synchronize; it runs on `workflow_dispatch` only. Bash 3.2 and macOS system awk run locally before push, not in CI. See [AgDR-0259](AgDR-0259-no-macos-ci-runners.md).

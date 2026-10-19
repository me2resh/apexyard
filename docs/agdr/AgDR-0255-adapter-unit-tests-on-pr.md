---
id: AgDR-0255
timestamp: 2026-10-19T10:00:00Z
agent: platform-engineer (Adel)
model: composer
session: n/a
trigger: user-prompt
status: executed
category: integrations
---

# AgDR-0255: Run harness adapter unit tests on pull requests

> In the context of harness adapter unit suites that only ran under credentialed conformance, facing PR drift with no CI signal, I decided to add a path-filtered, secret-free workflow that runs each adapter `npm test`, to catch regressions before merge, accepting a separate check name from the hook test suite.

## Context

Security review of PR #1770 found that `harness-adapters/opencode` and `harness-adapters/pi` unit tests never run on pull requests. `conformance.yml` installs those adapters, but only on a schedule or manual dispatch, and it needs harness API keys. A failing unit test on a PR therefore gives no check.

Both adapters declare `engines.node >= 22` and a `test` script (`node --test test/*.test.ts`). Their suites mock exec. They need no secrets and no model API. Codex has no unit suite under `harness-adapters/`.

Ticket: me2resh/apexyard#1781.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add a job inside `tests.yml` | One workflow file | Couples adapter install to the hook-test tier matrix. Harder path filter |
| New workflow `adapter-tests.yml` with path filters | Clear scope. Skips when adapters and hooks are untouched. Matches `shellcheck.yml` shape | Extra check name for reviewers |
| Extend `conformance.yml` to PR without secrets | Reuses install steps | Mixes credentialed live turns with hermetic unit tests. Easy to reintroduce secrets |

## Decision

Chosen: **new workflow `.github/workflows/adapter-tests.yml`**.

- Triggers: `pull_request` and `push` to `dev`.
- Paths: `harness-adapters/**`, `.claude/hooks/**`, and the workflow file.
- Matrix: `opencode`, `pi` (adapters with an offline `test` script).
- Runtime: Node 22 via `actions/setup-node` (same SHA as other workflows). `npm ci` then `npm test`.
- Permissions: `contents: read`. No secrets. No model calls.
- Keep `conformance.yml` unchanged for credentialed live turns (AgDR-0095).

## Consequences

- A PR that changes an adapter or hooks runs that adapter's unit suite in CI.
- A PR that touches neither path skips the workflow (GitHub path filters).
- Reviewers see check names `opencode unit tests` and `pi unit tests`, not `hook test suite`.
- Shared `_shared` tests stay covered by adapter derive-gates suites. They are not a separate matrix entry (no package `test` script).

## Architecture evolution

### Before

Only `conformance.yml` installed opencode and pi adapters. That workflow needed secrets for real harness turns. Adapter unit tests had no PR check.

### After

Hermetic adapter unit tests run on path-matched PRs and on pushes to `dev`. Conformance stays the credentialed live-turn matrix. The two workflows do not share jobs or secrets.

## Artifacts

- Issue: me2resh/apexyard#1781
- Workflow: `.github/workflows/adapter-tests.yml`
- Related: [AgDR-0095](AgDR-0095-conformance-ci-badge.md), [AgDR-0236](AgDR-0236-tiered-ci.md)

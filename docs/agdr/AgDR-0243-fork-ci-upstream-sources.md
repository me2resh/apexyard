---
id: AgDR-0243
timestamp: 2026-10-17T12:00:00Z
agent: claude-code
model: claude-opus-5-5
session: 1db99c62-d1aa-4904-b503-9d08b57ba95e
trigger: user-prompt
status: executed
category: patterns
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Fork CI reads framework-owned inputs from upstream

> In the context of fork CI on upstream sync PRs, facing checks that fail on content the adopter did not write, I decided to read framework-owned inputs from me2resh/apexyard to achieve a green sync PR, accepting one network fetch from upstream per run.

## Context

Two checks fail on every fork sync PR (#1741, #1742).

- The hook-test snapshot proof fetches `refs/pull/1466/head` from `$GITHUB_REPOSITORY`. That ref exists only in upstream.
- records-lint lints each record that changed against the PR base. A sync PR adds all of `docs/orbit/` to the fork. Shipped records fail newer lint rules, so the fork PR fails.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Skip both checks on forks | Simple | Forks lose the snapshot proof and lint their own records less |
| Edit every shipped record to pass the lint | No workflow change | Rewrites past plan and reconciliation records. A future lint rule breaks forks again. |
| Read framework-owned inputs from upstream | Forks keep both checks. History stays unchanged. | One fetch from upstream per run |

## Decision

Chosen: **read framework-owned inputs from upstream**, because the fork keeps full checks on what it owns.

- The snapshot proof always fetches from `me2resh/apexyard`.
- On a fork, the records-lint workflow fetches upstream `dev` and passes `--upstream`. records-lint skips a changed record when its blob is identical to the upstream blob at the same path. Records that differ from upstream, or that upstream does not have, are still linted.
- If the upstream fetch fails, the workflow does not pass `--upstream`. The lint then checks every changed record, as before.
- `--upstream` with a ref that does not resolve fails closed.

## Consequences

- Fork sync PRs no longer fail on shipped records or on the snapshot ref.
- A fork that edits a shipped record gets that record linted.
- Upstream CI does not change.

## Artifacts

- Issues #1741 and #1742.

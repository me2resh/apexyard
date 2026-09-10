---
id: AgDR-0144
timestamp: 2026-09-10T00:00:00Z
agent: codex
model: gpt-6
trigger: user-prompt
status: executed
category: security
---

# Dismiss stale forge approvals on protected branches

> In the context of ApexYard's SHA-bound local review markers and GitHub's independent approval state, facing a green approval that can describe an older commit, I decided to enable `dismiss_stale_reviews_on_push` for `dev` and `main`, to keep the forge UI aligned with the current PR head, accepting that every new commit requires a fresh GitHub review.

## Context

The local merge gate compares the Rex marker and human approval marker with the PR head SHA. GitHub's branch-protection ruleset separately counted an earlier approval after a later push because stale-review dismissal was disabled. The controls therefore disagreed: ApexYard correctly required fresh local markers while the forge could still display a green approval for an old commit.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Enable `dismiss_stale_reviews_on_push` | Directly invalidates every prior approval after a push; applies uniformly to `dev` and `main`; matches the stale-state failure | Every new commit requires a fresh review, including harmless documentation changes |
| Enable `require_last_push_approval` | Adds a separation-of-duties check for the latest pusher | Does not remove all earlier approvals from the UI and does not directly express the stale-approval problem |
| Leave GitHub unchanged | No settings mutation | Leaves the forge UI able to imply current approval for an old commit |

## Decision

Chosen: **enable `dismiss_stale_reviews_on_push`** in the shared `Branch-Protection` ruleset covering `refs/heads/dev` and `refs/heads/main`. This is the narrow setting that closes #1197's observed mismatch. The local SHA-bound markers remain the load-bearing ApexYard gate.

## Consequences

- A push to either protected branch's PR invalidates prior GitHub approvals and requires a fresh review.
- The policy is enforced by GitHub for every contributor, while the local marker gate remains independent and SHA-bound.
- The setting must be rechecked if the ruleset is recreated or split into branch-specific rulesets.

## Artifacts

- me2resh/apexyard#1197
- GitHub ruleset `Branch-Protection` (ID `17953324`)
- `.claude/rules/pr-workflow.md`
- `docs/release-process.md`

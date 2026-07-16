# Gate `scorecard.yml` to the Canonical Repo

> In the context of `.github/workflows/scorecard.yml` (OSSF Scorecard) running unconditionally on `push` / `schedule` / `branch_protection_rule`, facing the fact that every adopter fork inherits the workflow and shows a persistent, non-actionable red ❌ (Scorecard can only publish results for the tracked canonical project), I decided to add a job-level `if: github.repository == 'me2resh/apexyard'` guard to achieve a clean CI signal on forks without weakening the scan on the canonical repo, accepting that adopters who want their own Scorecard run must explicitly re-enable the job for their fork.

## Context

`scorecard.yml` runs OSSF Scorecard's supply-chain security analysis and publishes results to the Security > Code scanning tab (see #518). It has no repo guard, so cloning/forking apexyard (which every adopter does per the framework's fork-based distribution model) inherits the workflow verbatim. On a fork:

- `publish_results` cannot succeed — the OSSF badge API only accepts results for the tracked, canonical public repo
- The fork lacks the branch-protection / security metadata Scorecard expects, so the "Run analysis" step fails outright

The net effect is a red ❌ on every adopter fork's Actions tab that looks like a security regression but is actually structural noise — a false signal a new adopter has no way to distinguish from a real one.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| `if: github.repository == 'me2resh/apexyard'` | Always set on every trigger this workflow uses (`push`, `schedule`, `branch_protection_rule`); simple string equality; skips (not fails) on forks | Requires the canonical repo's exact `owner/name` hardcoded in the workflow |
| `if: ${{ !github.event.repository.fork }}` | Reads as "not a fork" | `github.event.repository` is **absent on `schedule` runs** — this workflow's primary trigger is a weekly cron, so the condition would evaluate to a falsy/undefined lookup unreliably rather than deterministically skip |
| Delete the workflow from `.github/workflows/` in each fork post-clone | No conditional logic needed | Not automatable at fork-creation time; every adopter would have to remember to delete it manually, and re-adding it upstream would silently reintroduce the failure for existing forks that already deleted their copy |
| Leave as-is, document the failure as expected/ignorable | Zero code change | A red ❌ that adopters are told to ignore erodes trust in the rest of the CI signal — exactly the failure mode this ticket exists to fix |

## Decision

Chosen: **`if: github.repository == 'me2resh/apexyard'`**, because `github.repository` is populated on every event type this workflow listens for — including `schedule`, where `github.event.repository.fork` does not exist — making it the only reliable, deterministic way to restrict the job to the canonical repo across all three triggers.

## Consequences

- The Scorecard job now **skips** (not fails) on every fork, on all three triggers (`push`, `schedule`, `branch_protection_rule`)
- No change to scan behavior, permissions, or steps on the canonical `me2resh/apexyard` repo
- An adopter who wants their *own* fork's Scorecard/badge published must intentionally edit the `if:` condition to their own `owner/repo` — a one-line, discoverable change, not a silent gap

## Artifacts

- me2resh/apexyard#907
- `.github/workflows/scorecard.yml`

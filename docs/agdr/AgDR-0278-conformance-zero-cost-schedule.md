# AgDR-0278: Conformance zero-cost schedule

> Facing daily failures and no API-key budget, the owner chose a hybrid schedule to retain daily opencode checks, accepting release-only pi and codex coverage.

## Context

This record amends [AgDR-0095](AgDR-0095-conformance-ci-badge.md) for [#1916](https://github.com/me2resh/apexyard/issues/1916).
The scheduled conformance workflow fails daily.
The repository has neither required provider API secret, and the owner has no budget for keys.
The opencode pin, `1.17.16`, cannot use the free tier, which requires version 1.18.0 or later.
The issue specifies `opencode-ai@1.19.4` as the replacement.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Provision API keys | Retains daily checks for all three harnesses. | Requires a budget that the owner does not have. |
| Use manual dispatch for all three | Removes daily model usage. | Removes every daily drift signal. |
| Use a hybrid schedule | Retains daily opencode checks without API keys. | Pi and codex lose daily coverage. |

## Decision

Chosen: **the hybrid schedule**, because it retains a daily check without requiring a provider API-key budget.

The daily matrix contains only opencode.
Manual dispatch and `workflow_call` retain all three harnesses.
The existing single-harness dispatch input remains available.
The opencode CLI pin becomes `1.19.4`.
Every job that runs retains its fail-closed credential check and error text.

Scheduled badge updates change only opencode's streak.
Pi and codex receive grey `manual` badges, and their stored streaks stay unchanged.
The dispatch streak guard from #880 remains in force.
The release-tier workflow remains unchanged and still requires `CONFORMANCE_ON_RELEASE`.

Before a release PR merges, the owner records local pi and codex gate evidence.
The owner must first confirm that provider terms allow scripted use of a subscription login.
Until then, use dedicated API keys with spending caps or record the step as not run.
This record does not assert that provider terms allow subscription scripting.

## Consequences

- Pi and codex lose their daily green streak and daily drift detection.
- Without an intervening manual dispatch, only the release evidence step can detect drift in pi and codex.
- Missing API credentials still fail pi and codex jobs on dispatch and release-tier calls.
- Main can turn green only after the next release, because scheduled workflows run from the default branch.
- The free opencode model can change without notice, so a successful installation does not guarantee conformance.
- Teams with keys can restore the schedule and publisher lists together, as described in the operator document.

## Artifacts

- [Issue #1916](https://github.com/me2resh/apexyard/issues/1916)
- [Conformance workflow](../../.github/workflows/conformance.yml)
- [Badge publisher](../../bin/conformance-publish-badge.sh)
- [Badge tests](../../.claude/hooks/tests/test_conformance_publish_badge.sh)
- [Conformance CI](../conformance-ci.md)
- [Release process](../release-process.md#local-conformance-evidence-before-merge)

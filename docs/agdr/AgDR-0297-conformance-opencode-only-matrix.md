# AgDR-0297: Conformance matrix runs opencode only

> The owner chose to remove pi and codex from the Conformance matrix until their keys are funded, and to move the opencode pin to 1.18.35.

## Context

This record amends [AgDR-0278](AgDR-0278-conformance-zero-cost-schedule.md) for [#2057](https://github.com/me2resh/apexyard/issues/2057).
AgDR-0278 kept pi and codex in the dispatch and `workflow_call` matrix.
Neither provider secret exists in the repository.
Every pi and codex job therefore fails closed, and any run that includes them is red.
The owner decided on 12 Nov 2026 to remove both harnesses until the owner funds their keys.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep pi and codex in the dispatch matrix | No workflow change. | Every dispatch and `workflow_call` run is red. |
| Remove them from the matrix, keep the steps | Runs are green when opencode passes. Re-adding is one line. | pi and codex have no CI coverage until keyed. |
| Delete the pi and codex steps | Smaller file. | Re-adding needs a larger change. |

## Decision

Chosen: **remove pi and codex from the matrix and keep their steps**.
The matrix is `["opencode"]` for every trigger.
A workflow comment lists how to re-add each harness and which secret it needs:
`CONFORMANCE_ANTHROPIC_API_KEY` for pi and `CONFORMANCE_OPENAI_API_KEY` for codex.
The opencode pin moves from `1.19.4` to `1.18.35`.
Version 1.18.35 is published on npm and is newer than the 1.18.0 free-tier minimum.
No assertion changes.
The fail-closed credential check stays for any harness that is re-added.

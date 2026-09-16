# Classify delegated gate paths as trust-chain controls

> In the context of the framework's git-native pre-push control delegating to a script under `bin/`, facing a path-trigger gap that could classify an enforcement change as ordinary work, I decided to include `.githooks/**` and delegated gate runners such as `bin/run-pre-push-checks.sh` in the trust-chain path set to preserve Heavy review coverage, accepting the additional Security Auditor review for these enforcement files.

## Context

- `.githooks/pre-push` decides whether a terminal push proceeds and delegates its checks to `bin/run-pre-push-checks.sh`.
- The role trigger and ceremony rules named production `.claude/hooks/**` and `.claude/settings.json` but omitted these paths.
- A path omission can turn an enforcement change into a Standard or Lean review by default.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep the existing path set | No documentation or trigger changes | Delegated gate edits remain easy to misclassify |
| Add `.githooks/**` and delegated gate runners | Classifies the complete control path as Heavy and gives the Security Auditor a mechanical trigger | These files receive an additional review pass |
| Document the exclusion | Makes the omission explicit | Keeps a weaker review posture for enforcement code |

## Decision

Chosen: **add `.githooks/**` and delegated gate runners such as `bin/run-pre-push-checks.sh` to the trust-chain path set**, because the hook and the script it executes jointly decide whether a push proceeds. The path trigger and right-size rail now use the same classification.

## Consequences

- Security Auditor activation covers the git-native hook and its delegated runner.
- Changes to the runner remain Heavy even when the diff is small.
- Other `bin/` utilities remain outside the trust chain unless they directly enforce a gate.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1302
- `.claude/hooks/detect-role-trigger.sh`
- `.claude/hooks/tests/test_detect_role_trigger.sh`
- `.claude/rules/role-triggers.md`
- `.claude/rules/right-size-ceremony.md`

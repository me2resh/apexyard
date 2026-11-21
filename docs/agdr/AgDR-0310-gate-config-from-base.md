---
id: AgDR-0310
timestamp: 2026-11-21T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
trigger: user-prompt
status: accepted
ticket: me2resh/apexyard#2104
---

# AgDR-0310: Read gate narrowing settings from the PR base branch

## Context

The architecture gate and the UI design gate read `design_paths`, `design_paths_exclude`, `ui_paths` and `ui_paths_exclude` from the git top folder where the hook runs. That folder is the checkout of the PR. A PR could edit `.claude/project-config.json` and switch off the gate that judges it.

## Decision

Read these settings from the base branch of the PR. The hook fetches `.claude/project-config.json` at the base ref through the forge API (`resolve_pr_base_config` in `_lib-extract-pr.sh`).

- Exclusion keys come from the base config only.
- The effective pattern list is the base list, or the broad defaults when the base config has no list.
- A local `design_paths` or `ui_paths` list only adds patterns. A PR can widen coverage. A PR cannot narrow it.
- If the base config cannot be read, the hook uses the broad defaults and no exclusions. This fails closed.
- Only the GitHub forge is read. A glab merge uses the broad defaults.

## Alternatives considered

- Require owner approval for any change to these keys. This adds a new approval flow. It is larger than the fix needs.
- Use `git show <base>:...` in the local clone. The clone may not hold the base ref. The forge API always has it.

## Consequences

- A PR that does not change these keys behaves as before, because base and head hold the same values.
- A PR that adds an exclusion or a narrowing list is still gated. The new exclusion takes effect after the PR merges.
- Each merge check makes one extra forge call. A failed call gives the defaults.

## Not changed: the AgDR commit gate

`require-agdr-for-arch-changes.sh` reads `architecture_paths` at commit time from staged files. It has no PR and no base ref. It is a local early check. The merge gates decide the outcome. This decision leaves it unchanged.

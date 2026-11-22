---
id: AgDR-0310
timestamp: 2026-11-21T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
trigger: user-prompt
status: accepted
ticket: me2resh/apexyard#2104
---

# AgDR-0310: Read gate narrowing settings from the PR base when the PR changes the config

## Context

The architecture gate and the UI design gate read `design_paths`, `design_paths_exclude`, `ui_paths` and `ui_paths_exclude` from the local project config. A PR that edits `.claude/project-config.json` could add an exclusion and switch off the gate that judges it.

`.claude/project-config.json` is gitignored on most setups. The base branch then has no copy. A rule that always reads the base copy would ignore every local setting and block merges that pass today. The first version of this change had that fault.

## Decision

Act only when the PR changes `.claude/project-config.json`. The gate already holds the PR changed-file list, so the check costs no forge call.

- Config not in the PR: use the local config exactly as before. No behaviour change and no extra forge call.
- Config in the PR: read `design_paths_exclude`, `ui_paths_exclude` and the path lists from the base branch copy (`resolve_pr_base_config` in `_lib-extract-pr.sh`).
- Base copy absent (404) or unreadable: use the built-in default paths and no exclusions. Print one `NOTE:` line to stderr.
- A local `design_paths` or `ui_paths` list may add patterns in both cases. A PR can widen coverage. A PR cannot narrow it.
- The fetch queries `refs/heads/<base>`, so a tag with the same name cannot be read.
- Only the GitHub forge is read. A GitLab merge request that changes the config uses the defaults. `docs/project-config.md` documents this.

## Alternatives considered

- Always read the base copy. This ignores gitignored local config and blocks merges that pass today. Rejected after review.
- Require owner approval for any change to these keys. This adds a new approval flow. It is larger than the fix needs.

## Consequences

- A PR that does not change the config behaves as before.
- A PR that changes the config is judged by the base settings. A new exclusion takes effect after that PR merges.
- The extra forge call happens only when the config is in the PR diff.

## Not changed: the AgDR commit gate

`require-agdr-for-arch-changes.sh` reads `architecture_paths` at commit time from staged files. It has no PR and no base ref. It is a local early check. The merge gates decide the outcome. This decision leaves it unchanged.

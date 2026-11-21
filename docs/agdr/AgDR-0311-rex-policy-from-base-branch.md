---
id: AgDR-0311
timestamp: 2026-11-21T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5-5
trigger: user-prompt
status: executed
category: architecture
---

# Load Rex policy from the base branch

> In the context of Rex reading guides, severity policy and handbooks from the PR checkout, facing a PR that can change the policy that judges it, I decided to load all policy from the PR base branch, to keep the verdict independent of the change under review (me2resh/apexyard#2105).

## Context

Recipe W3 in `docs/investigations/gate-load-source.md` shows the risk. A PR removes `ENFORCEMENT: blocking` from a handbook. Rex then reads the weakened copy and treats the rule as advisory. The PR approves its own exemption.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Load from the base branch with `git show` | No new script, no new trust root | Prompt-level rule; a contract test pins the text |
| Trusted manifest of paths and hashes | Strong | Needs a new manifest and its approval flow |
| Keep the PR checkout | No change | The PR controls the policy |

## Decision

Chosen: **base-branch loading**. Rex reads handbooks, guides, the severity policy and `custom-templates/REVIEW.md` with `git show origin/<base>:<path>` or the GitHub contents API at the base ref. Rex lists handbooks with `git ls-tree` at the base ref. A changed guide or handbook is part of the diff. It never sets the verdict, the blocking status or the load list for the same PR. The `/code-review` skill resolves the policy from the base branch and gives Rex the base ref.

## Consequences

- A PR that edits policy takes effect only after merge.
- A policy change in the PR is reported for human approval.
- The rule is prompt-level. `.claude/hooks/tests/test_rex_base_branch_policy.sh` pins the text and proves that a base-ref read ignores a weakened head.
- The manifest option stays open if prompt-level loading proves too weak.

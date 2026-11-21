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

Chosen: **base-branch loading, scoped by repository**. The `/code-review` skill does not pass a base ref. Rex resolves it himself, because `git fetch` is blocked during review.

- Files in the PR's own repository (public handbooks, guides, severity policy, `custom-templates/REVIEW.md`) load from the PR base. Rex reads `baseRefName` and `baseRefOid` with `gh pr view <pr> --repo <owner/repo> --json baseRefName,baseRefOid`. He reads each file with `gh api repos/<owner/repo>/contents/<path>?ref=<baseRefOid>` and lists paths with `gh api repos/<owner/repo>/git/trees/<baseRefOid>?recursive=1`. The base SHA avoids a stale `origin/<base>`.
- Files in another repository (the private `custom-handbooks/` layer, ops-fork guides for a managed-project PR) load from that repository's default branch as checked out in the ops fork. The PR cannot change them. A blocking private handbook is still applied.
- A handbook or guide that exists only on the PR head is diff content. Rex reviews it and never applies it. A changed copy never sets the verdict, the blocking status or the load list for the same PR.

## Consequences

- A PR that edits policy takes effect only after merge.
- A policy change in the PR is reported for human approval.
- The rule is prompt-level. `.claude/hooks/tests/test_rex_base_branch_policy.sh` pins the text and proves that a base-ref read ignores a weakened head.
- The manifest option stays open if prompt-level loading proves too weak.

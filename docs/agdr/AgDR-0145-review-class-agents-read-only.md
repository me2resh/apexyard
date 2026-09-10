# Review-class agents are read-only during the active review window

> In the context of a review-class agent being able to mutate and push the PR it is reviewing, facing a silent loss of author-reviewer separation, I decided to enforce a read-only repository boundary with a scoped PreToolUse control plus prompt guardrails, to preserve independent review evidence, accepting that command-text classification has a bounded pattern surface and that the active-reviewer marker must remain trustworthy.

## Context

Issue #1233 reproduced a review-class agent editing, committing, and pushing to the PR branch before writing its approval marker. The merge gate rejected the stale marker because the PR head changed, but the review record did not explain that the reviewer had become an author. The three review-class agents use Bash for read-only inspection and review submission, so removing Bash would remove required capability.

The active-reviewer marker already identifies the sanctioned review window for `code-reviewer`, `security-reviewer`, and `solution-architect`. It is written immediately before the reviewer is spawned and cleared after the review. That signal is sufficient to scope a blocking command control without blocking ordinary orchestrator work outside the review window.

## Options Considered

| Option | Pros | Cons |
|---|---|---|
| Prompt-only prohibition | Small change; clear agent instruction | Advisory only. A helpful model can still mutate the repository. |
| Gate-side commit-identity check | Detects authoring after the fact | Single-account operation makes author and reviewer identities indistinguishable; it diagnoses late and does not prevent working-tree collisions. |
| Remove Bash from review agents | Strong tool reduction | Reviewers need Bash for tracker queries, local inspection, and review submission. It would require a new restricted tool surface. |
| Scoped PreToolUse control plus prompt guardrails | Blocks common repository-mutating git commands before execution while retaining read-only shell access; prompts explain the boundary | Command classification has a bounded pattern surface; future mutation forms need regression cases. |

## Decision

Chosen: **scoped PreToolUse control plus prompt guardrails**, because the existing active-reviewer marker provides a narrow lifecycle signal and the control prevents the failure before it reaches the worktree or remote. `block-reviewer-repo-mutation.sh` blocks mutating git subcommands while the marker exists, while allowing evidence commands such as `git status` and `git diff`. The three review-agent prompts state the same read-only boundary and direct fixes to the orchestrator or build agent.

The control deliberately does not claim to detect every arbitrary script that can write files. Review agents remain constrained by their `Write`/`Edit` disallow list, and the prompt plus the marker-scoped hook cover the observed git mutation path. New bypass shapes must add a focused test and update this decision record.

## Consequences

- A reviewer cannot stage, commit, push, restore, reset, stash, clean, switch, or otherwise mutate refs through the common `git` command forms while the review marker is active.
- Read-only Git inspection and tracker commands remain available to the review agents.
- The orchestrator should wait for the reviewer before making repository changes in the same session, avoiding shared-tree races.
- A malformed or novel mutation command may require a future matcher extension; the documented limitation is preferable to treating a prompt-only rule as enforcement.
- The active-reviewer marker remains a trust-chain input and must be cleared after each review, as already required by the review skills.

## Artifacts

- `.claude/hooks/block-reviewer-repo-mutation.sh`
- `.claude/hooks/tests/test_block_reviewer_repo_mutation.sh`
- `.claude/settings.json`
- `.claude/agents/code-reviewer.md`
- `.claude/agents/security-reviewer.md`
- `.claude/agents/solution-architect.md`
- `.claude/rules/pr-workflow.md`
- Issue #1233

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
- ~~The orchestrator should wait for the reviewer before making repository changes in the same session, avoiding shared-tree races.~~ Replaced on 2026-10-11 (see Amendment): the orchestrator and build agents never wait for a review.
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

## Amendment — 2026-10-11, #1649

### Why

The session-wide marker locked every caller in the session. On 2026-10-11 it held up build commits and orchestrator work during reviews. Reviews also ran one at a time, because two reviews shared one marker file.

### Decision

1. **Trust root: the harness-set agent type.** Claude Code sets `agent_type` and `agent_id` in the hook input of every tool call that a sub-agent makes. A main-thread call has neither field. We captured real payloads from a code-reviewer sub-agent, a general-purpose sub-agent and the main thread. The sanitised copies are in `.claude/hooks/tests/fixtures/pretooluse-payloads/`.
2. **Who is a review agent.** A call is a review call when `agent_type` is `code-reviewer`, `security-reviewer` or `solution-architect`. One shared helper, `review_caller_class` in `_lib-review-markers.sh`, decides this for all five hooks. The marker is a fallback for one case only: a sub-agent with an `agent_id` and no `agent_type`.
3. **Who is never blocked.** The orchestrator (no agent fields) and every other typed agent, such as a build agent, are never blocked by the lock. The lock applies to review agents. The lock still needs an active marker for the session. A payload that cannot be parsed fails closed while a marker exists.
4. **One marker per review.** The key is session, repo, PR and review kind. The path is `.claude/session/active-reviewers/<session>/<repo>__<pr>-<kind>`, built by `active_reviewer_marker_path` with the extra arguments. Each review clears only its own file. SessionStart clears the set of this session only. The legacy single file is still read during the transition, and a review skill may still write it.
5. **Replaced consequence.** The line that made the orchestrator wait for the reviewer is replaced. Reviews, builds and orchestrator work now run at the same time. A shared-tree race is avoided because a reviewer works in a scratch clone and cannot mutate the repository.
6. **A typed non-review agent gets no grant from the marker.** `warn-review-marker-write.sh` and the scratch-clone exemption in `require-active-ticket.sh` no longer treat a build agent as the sanctioned reviewer.

### Requirement on Claude Code

The lock needs a Claude Code build that sends `agent_type` in hook input. We verified this on 2.1.296. We did not test older builds and state no earliest version.
On a build that sends neither `agent_type` nor `agent_id`, a review agent cannot be told from the main thread, so the lock does not block it. The merge gates still hold.
A session-start warning for an old build is not possible: a hook cannot read the version from its input or a trusted variable.
The review skills spawn the reviewer only by its own agent type. If the shared helper file is missing, the mutation hook still blocks a payload whose `agent_type` is a review agent, and blocks any caller while a marker exists.

### What does not change

- `block-unreviewed-merge.sh` and `block-merge-on-red-ci.sh` are unchanged (constraint C1). An approval for a stale head commit still blocks at the merge gate.
- The mutation patterns in `block-reviewer-repo-mutation.sh` are unchanged.

### Residual risk

The agent type is set by the harness, not by the agent. A tool call that runs outside a sub-agent carries no type, so the lock cannot see it. A review agent cannot hide its type. A forged marker file only widens the lock for an untyped sub-agent.

### Artifacts

- `.claude/hooks/_lib-review-markers.sh`
- `.claude/hooks/block-reviewer-repo-mutation.sh`
- `.claude/hooks/block-reviewer-ci-wait.sh`
- `.claude/hooks/warn-review-marker-write.sh`
- `.claude/hooks/require-active-ticket.sh`
- `.claude/hooks/auto-code-review.sh`
- `.claude/hooks/clear-active-reviewer-marker.sh`
- `.claude/hooks/tests/test_review_agent_detection.sh`
- `.claude/hooks/tests/fixtures/pretooluse-payloads/`
- `bin/token-cost.py` (the `locks` view)

## Amendment — 2026-10-11, me2resh/apexyard#1653

### Decision

`review_markers.extra_review_agents` in `.claude/project-config.json` adds exact review agent types.
The lock list is the union of built-in types and validated extra types.
The built-in types stay fixed.
The config cannot remove types or use patterns.
The fallback uses only built-in types when the library is missing.
Only a typed non-built-in sub-agent triggers a config read.

### Consequence

Adopters can lock custom review agents, including plugin types, during an active review.
Invalid entries do not widen the lock.
A name shared with a build agent also locks that build agent.

### Artifacts

- `.claude/hooks/_lib-review-markers.sh`
- `.claude/project-config.defaults.json`
- `.claude/hooks/tests/test_review_agent_extra_types.sh`

---
id: AgDR-0135
timestamp: 2026-09-08T06:00:00Z
agent: Codex
model: GPT-6
session: issue-1184
trigger: user-prompt
status: executed
category: architecture
---

# Normalize linked worktrees to the main ops root

> In the context of linked worktrees for an ops fork, facing split review-marker state, I decided to resolve the main worktree from Git's common directory data to keep gate state in one location, accepting the need to handle stale pins.

## Context

`resolve_ops_root` can return a linked worktree instead of the main ops-fork checkout. Review markers then use different roots depending on the worktree. A merge gate can miss a valid approval. The resolver must work for nested and out-of-tree linked worktrees.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Remove the tracked `.apexyard-fork` anchor | Simple walk-up change | Does not fix out-of-tree worktrees and requires migration. |
| Normalize linked worktrees to the main worktree | Uses Git metadata and covers all worktree locations | Requires resolver and pin tests. |
| Copy markers between worktrees | No resolver change | Creates ambiguous and unsafe approval state. |

## Decision

Chosen: **Normalize linked worktrees to the main worktree**, because Git provides authoritative common-directory data and one root keeps review markers consistent.

## Consequences

- Resolver callers receive one ops-fork root from main and linked worktrees.
- Existing stale pins must normalize or fail closed.
- Tests must cover nested, out-of-tree, pinned, and pinless worktrees.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1184

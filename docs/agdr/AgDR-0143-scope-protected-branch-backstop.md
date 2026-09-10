---
id: AgDR-0143
timestamp: 2026-09-10T00:00:00Z
agent: codex
model: gpt-6
trigger: user-prompt
status: executed
category: security
---

# Scope the protected-branch backstop to its target repository

> In the context of session-pinned ops-root resolution, facing a process-wide protected-branch hook that can inspect an unrelated repository, I decided to scope `block-main-push.sh` to the command's actual Git repository and its linked worktrees, to prevent false blocks without weakening the protected-branch gate, accepting that managed-project clones will no longer use this ops-fork backstop.

## Context

The settings wrapper uses a session pin to find the ops-root hook quickly. That pin identifies where the hook is stored. It does not identify the repository targeted by the Bash command.

Before this change, a plain commit in an unrelated repository could resolve the pinned ApexYard hook and be blocked because the unrelated repository used a protected branch name such as `main`. This was safe-direction enforcement, but it was wrong repository resolution and prevented unrelated work.

The hook remains a blocking trust-chain control for the repository it governs. The scope check is enabled only by the settings wrapper. Direct hook invocations and existing unit fixtures retain their prior behavior. The check resolves `cd` targets and `git -C` targets, compares their Git toplevel and common Git directory with the hook repository, and permits linked worktrees of that repository.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the pin as the repository scope | No code change | Blocks unrelated repositories and cannot distinguish a managed-project clone from the ops fork |
| Resolve any ApexYard-shaped ancestor | Preserves some managed-project coverage | Still treats nested managed-project clones as the ops fork and repeats the wrong-repository failure |
| Compare the command target with the pinned hook repository | Matches the command's actual repository; preserves linked worktree coverage; prevents unrelated false blocks | The ops-fork backstop no longer protects managed-project clones that do not share the ops repository |
| Disable the backstop globally | Removes false blocks | Removes protected-branch protection and violates the existing trust-chain decision |

## Decision

Chosen: **compare the command target with the pinned hook repository**, using Git's toplevel and common Git directory. The settings wrapper sets `APEXYARD_OPS_SCOPE_GUARD=1); the hook then skips commands whose actual target is unrelated. A target is in scope when it is the pinned repository or a linked worktree of that repository.

## Consequences

- Commits and pushes in unrelated repositories are no longer blocked by the ApexYard protected-branch backstop.
- The pinned ApexYard repository and its linked worktrees retain the existing protected-branch behavior.
- Managed-project clones outside the ops repository are intentionally outside this repository-scoped backstop. Their own project controls remain responsible for their branches.
- Regression tests cover unrelated repositories, nested managed-project clones, the pinned repository, and `git -C` targets.

## Artifacts

- me2resh/apexyard#1230
- `.claude/settings.json`
- `.claude/hooks/block-main-push.sh`
- `.claude/hooks/tests/test_block_main_push.sh`
- AgDR-0114 (blocking backstop decision)

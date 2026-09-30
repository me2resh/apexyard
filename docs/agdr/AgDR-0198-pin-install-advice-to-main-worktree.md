# Require a valid session pin for pre-push install advice

> Issue #1491 found that an unpinned reminder could trust a repository's own fork marker.
> I require a valid session pin before the reminder suggests installing hooks.
> I compare the pin with the checked repository's main worktree to support linked worktrees.
> An unpinned session receives no install advice.

## Context

`pre-push-gate.sh` advises operators about the Git native pre-push hook.
AgDR-0173 limits that advice to the ApexYard fork.
The shared ops-root resolver uses a session pin when one exists.
Without a valid pin, it walks upward and can accept a marker from the checked repository.
A linked worktree resolves to the fork's main checkout, but Git reports the linked worktree as the checked repository root.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep the resolver fallback | Preserves advice in unpinned sessions | A checked repository can supply its own marker |
| Require a valid pin and compare main worktrees | Prevents unpinned install advice and supports linked worktrees | An unpinned fork receives no reminder |

## Decision

Chosen: **Require a valid pin and compare main worktrees**.
The hook validates the pin with the shared ops-root library.
It finds the checked repository's main worktree through Git's common directory.
It suggests installation only when those roots match.
It compares the two roots by file identity, not by path text (AgDR-0206, #1504).
It stays silent when the pin is missing, disabled, or invalid.

## Consequences

- A pinned session in the fork receives install advice when its Git native hook is absent.
- A pinned session in a linked worktree receives the same advice.
- A session without a valid pin receives no install advice.
- A pinned session in another repository receives a scope note without install advice.

## Artifacts

- Issue #1491
- Issue #1504 and AgDR-0206
- `.claude/hooks/pre-push-gate.sh`
- `.claude/hooks/tests/test_pre_push_gate.sh`
- `docs/agdr/AgDR-0173-git-native-pre-push-command-execution.md`

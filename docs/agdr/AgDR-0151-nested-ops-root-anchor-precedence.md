# Prefer explicit v2 anchors for nested ops-root resolution

> In the context of a framework fork nested under an enclosing Git repository, facing conflicting child-directory anchors and incorrect pin normalization, I decided to prefer a unique `.apexyard-fork` child and preserve ordinary subdirectory paths to keep portfolio and session state on the fork, accepting that multiple explicit v2 children remain ambiguous.

## Context

- `resolve_ops_root_walk` inspects immediate child directories when the Git toplevel can contain a nested framework fork.
- The scan previously counted the v2 marker and the legacy v1 pair as equal candidates.
- A split-portfolio layout can therefore produce two matches and resolve no fork.
- `_ops_root_main_worktree` also treated every path below a Git repository as a linked worktree.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep equal candidate handling and normalize every path to the Git main worktree | Preserves the existing implementation | Split-portfolio siblings remain ambiguous and subdirectory forks resolve to the enclosing repository |
| Prefer one v2 child and distinguish linked worktrees from ordinary subdirectories | Preserves explicit v2 intent, fixes pin validation, and keeps existing linked-worktree behavior | Requires additional resolver and pin regression tests |
| Search all descendants for the marker | Finds deeper nested forks | Can cross repository boundaries and select an unrelated fork |

## Decision

Chosen: **prefer a unique v2 child and normalize only linked worktrees**, because the explicit `.apexyard-fork` marker is stronger evidence than a legacy compatibility heuristic, while Git metadata distinguishes linked worktrees from ordinary subdirectories.

- A unique `.apexyard-fork` child wins over v1-pair siblings.
- Multiple v2 children remain ambiguous.
- A normal subdirectory keeps its own path.
- A linked worktree still normalizes to the main checkout.

## Consequences

- Split-portfolio registry, workspace, and onboarding paths resolve from the fork in an enclosing Git repository.
- Valid pins continue to resolve to a subdirectory fork.
- Existing linked-worktree marker state remains centralized in the main checkout.
- The resolver does not select among multiple explicit v2 forks.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1304
- Pull request: https://github.com/me2resh/apexyard/pull/1305
- `.claude/hooks/_lib-ops-root.sh`
- `.claude/hooks/tests/test_ops_root.sh`
- `.claude/hooks/tests/test_resolve_ops_root_pin.sh`
- `.claude/hooks/tests/test_portfolio_paths_nested_mixed_anchors.sh`

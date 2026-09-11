# Discover a single nested ops fork from an enclosing repository

> In the context of ops-root discovery, facing a fork nested inside an unrelated enclosing Git repository, I decided to inspect immediate child directories for one anchored fork before the existing upward walk, to avoid silently resolving against the enclosing repository.

## Context

The resolver walks upward from the Git toplevel. If an unrelated parent directory is itself a Git repository, that toplevel can be one level above the ops fork. An upward-only walk cannot descend into the fork and can therefore select the wrong root or report misleading missing configuration.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep the upward-only walk | No code change | The nested fork remains undiscoverable and path state can split silently. |
| Search all descendants | Finds more layouts | It can cross project boundaries and select a distant or unrelated fork. |
| Inspect immediate children and require one match | Covers the reported layout and avoids guessing | Deeper nesting remains unsupported; multiple matching children remain unresolved. |

## Decision

Chosen: **inspect immediate child directories for exactly one ops-root anchor** (`.apexyard-fork` or the legacy configuration pair) before walking upward. Return that child when there is one match. If there are zero or multiple matches, retain the existing upward walk and its fail-soft miss behavior.

## Consequences

- A fork nested one level below an enclosing Git repository resolves to the fork.
- Multiple candidate forks do not cause an arbitrary selection.
- Existing direct and workspace-clone resolution remains unchanged.
- Deeper nesting still requires an explicit start directory or a future scoped change.

## Artifacts

- `.claude/hooks/_lib-ops-root.sh`
- `.claude/hooks/tests/test_ops_root.sh`
- Issue #1270

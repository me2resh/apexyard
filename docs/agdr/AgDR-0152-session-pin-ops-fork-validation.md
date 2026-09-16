# Require framework hooks for session ops-root pins

> In the context of split-portfolio sessions where a private portfolio sibling carries the legacy v1 anchor pair, facing the risk that session state resolves to the data repository instead of the framework fork, I decided to require `.claude/hooks` for pin validation and pin writes to preserve a trusted ops-root identity, accepting that anchor-shaped directories without framework hooks will no longer be pin targets.

## Context

- Split-portfolio v2 stores `onboarding.yaml` and `apexyard.projects.yaml` in a private sibling repository.
- Those files are also the legacy v1 ops-root anchor pair.
- A session pin that trusts the sibling can direct hooks and marker state away from the framework fork.
- Walk-up resolution already prefers a unique `.apexyard-fork` child when both layouts are siblings.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Accept every anchored pin | Minimal change | A hookless portfolio sibling can become the trusted ops root |
| Require `.claude/hooks` for pin reads and writes | Identifies the framework fork and self-heals stale sibling pins | An anchor-shaped directory without framework hooks cannot be pinned |
| Remove v1 anchor support | Removes the ambiguity | Breaks un-migrated v1 adopters |

## Decision

Chosen: **require `.claude/hooks` for session pin reads and writes**, while retaining both v1 and v2 anchor support for walk-up resolution. A pinned path must satisfy an ops-root anchor and contain the framework hook directory. The SessionStart pin writer applies the same check before creating or replacing a pin.

## Consequences

- A pin to a split-portfolio data sibling is rejected and resolution falls back to the shared walk-up, where a unique v2 fork is preferred.
- A SessionStart run from the sibling workspace writes the v2 fork path instead of the sibling path.
- Existing v1 adopters continue to resolve through the walk-up and can pin normally when their fork contains `.claude/hooks`.

## Artifacts

- Issue: https://github.com/me2resh/apexyard/issues/1303
- `.claude/hooks/_lib-ops-root.sh`
- `.claude/hooks/pin-ops-root.sh`
- `.claude/hooks/tests/test_resolve_ops_root_pin.sh`

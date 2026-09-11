# Require an explicit tracker repository across project boundaries

> In the context of raw GitHub tracker commands from an ApexYard session, facing ambient repository selection that can return or mutate a different project's issues, I decided to require `--repo` or `-R` when the active ticket repository differs from the current checkout or when active tickets are ambiguous.

## Context

Framework helpers already pass resolved repositories to their tracker calls. Raw `gh issue` and `gh pr` commands remain able to use GitHub's ambient repository selection. When an operator runs from the ops fork with a managed-project ticket active, that ambient selection can resolve to the framework repository and return authoritative-looking state for the wrong project.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Rely on command conventions | No hook changes | A missed flag can read or write the wrong repository. |
| Block every unqualified tracker command | Strong mechanical boundary | It also blocks safe commands when the checkout origin already matches the active ticket. |
| Require explicit targeting only across a detected boundary | Blocks the dangerous ambiguity and preserves same-repo ergonomics | Marker discovery is limited to active ticket files and cannot identify an unstarted project. |

## Decision

Chosen: **add a Bash PreToolUse control for raw `gh issue` and `gh pr` commands**. If active ticket markers identify one repository and it matches the checkout origin, ambient use remains available. If the target differs, or multiple active repositories exist, the command is blocked until it includes `--repo` or `-R`. Sessions without a repo-bearing active marker retain existing behavior.

## Consequences

- Managed-project tracker operations cannot silently fall back to the ops-fork repository.
- Explicit cross-repository framework maintenance remains possible.
- Same-repository commands do not need a redundant repository flag.
- Commands that use other GitHub API shapes, such as raw `gh api`, remain governed by their existing controls and are outside this narrow guard.

## Artifacts

- `.claude/hooks/block-ambient-tracker-repo.sh`
- `.claude/settings.json`
- `.claude/hooks/tests/test_block_ambient_tracker_repo.sh`
- Issue #1268

# Add build.isolation setting, keep worktree as the default

> In the context of issue #1381 asking to prefer a local ticket branch over a worktree, facing adopters who want in-place testing without dropping the safe default, I decided to add `build.isolation` with values `worktree` (default) and `branch`. Parallel builds always use worktrees. This keeps the isolation protection from #784 while letting a team opt into local-branch builds.

## Context

Issue #1381 asked the framework to make a ticket branch in the local copy the default. Maintainers disagreed. Flipping the default would weaken the isolation rule that #784 and AgDR-era isolated builds established. Teams that want local-checkout builds still need a clear, documented path.

`build.isolation` is the compromise. The shipped default stays `worktree`. An adopter sets `"build": {"isolation": "branch"}` in `.claude/project-config.json` when the team wants agents to create the ticket branch in the local checkout.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A — Flip the default to local-branch builds | Matches the issue proposal. Developers see changes in place. | Removes the safe-by-default protection for every adopter. Parallel and risky builds become easy to get wrong. |
| B — Add `build.isolation` with default `worktree` (chosen) | Keeps current safe default. Teams can opt into `branch`. Docs stay explicit. | Adopters who want local branches must set a config key. |
| C — Leave behaviour unchanged and document worktrees better | No code or config change. | Does not close the adopter confusion the issue reports. |

## Decision

Chosen: **Option B**. Ship `build.isolation` in `.claude/project-config.defaults.json` with value `worktree`. Document both modes in `isolated-builds.md`, `/fan-out`, and the build-class agent files.

Rules that stay fixed:

1. In `branch` mode, the agent runs `git status` first. It refuses to switch branches when the working tree has uncommitted changes. It says why.
2. Parallel builds (`/fan-out`, Workflows) always use worktrees, regardless of the setting.
3. Harness `isolation` option behaviour is out of scope for this change.

## Consequences

- Adopters who do nothing keep worktree isolation.
- Adopters who set `branch` get local-checkout builds for single tasks on a clean tree.
- Fan-out and other parallel writers never share one checkout.
- A static test pins the default and the documentation contract.

## Artifacts

- `.claude/project-config.defaults.json` — `build.isolation`
- `.claude/rules/isolated-builds.md`
- `.claude/skills/fan-out/SKILL.md`
- `.claude/agents/{backend,frontend,platform,data}-engineer.md`
- `docs/project-config.md`
- `.claude/hooks/tests/test_config_build_isolation.sh`

## Architecture evolution

### Before

Spawned build agents were instructed to prefer `isolation: "worktree"` always. There was no project setting. Teams that wanted local-branch builds had no supported path.

### After

`build.isolation` selects the single-task mode. `worktree` remains the default. `branch` is opt-in and requires a clean working tree. Parallel work always uses worktrees. Reasoning: keep the protection that isolation exists for, and give teams a documented escape hatch without flipping behaviour for everyone.

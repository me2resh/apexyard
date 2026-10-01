# AgDR-0210: Add build.isolation setting, keep worktree as the default

> Add `build.isolation` with values `worktree` (default) and `branch` for the whole ops fork. The orchestrator permits `branch` only for foreground builds with no other active writer on the checkout. Background or concurrent build spawns use worktrees.

## Context

[#1381](https://github.com/me2resh/apexyard/issues/1381) asked for ticket branches in the local copy by default.
The [maintainer decision on #1381](https://github.com/me2resh/apexyard/issues/1381#issuecomment-5842988342) kept worktrees as the default and allowed an opt-in `build.isolation` setting.
[#784](https://github.com/me2resh/apexyard/issues/784) established the safe isolated-build pattern.
[#1024](https://github.com/me2resh/apexyard/issues/1024) added the worktree location, naming, and cleanup conventions.
[AgDR-0066](AgDR-0066-per-worktree-ticket-marker-tier.md) separates ticket markers for concurrent agents on the same managed project.
Local branch builds must retain these worktree protections when concurrency requires them.

An adopter sets `"build": {"isolation": "branch"}` in `.claude/project-config.json` to opt into local branch builds.
The setting applies to the whole ops fork, not per project.
A managed project's `workspace/<name>` clone counts as "the local copy" for that project.
`branch` mode can apply when that clone is the current repository and the conditions below hold.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A — Make local branches the default | Developers see changes in place. | Removes default isolation for every adopter. |
| B — Add `build.isolation` with default `worktree` (chosen) | Keeps the default protection. Teams can opt into `branch`. | The orchestrator must check concurrency before spawning. |
| C — Document existing worktrees only | No config change. | Leaves local branch builds unsupported. |

## Decision

Choose **Option B**. Ship `build.isolation` with value `worktree` in `.claude/project-config.defaults.json`.
Document both modes in the isolation rule, `/fan-out`, and all seven build-class agents.

`branch` mode applies only to a foreground build spawn when no other writer is active on that checkout.
A background build spawn always uses a worktree, regardless of `build.isolation`.
Any build spawn while another writer is active on that checkout uses a worktree, regardless of `build.isolation`.
Parallel means overlapping writers, including a build agent still working from an earlier spawn.
The orchestrator decides the mode at spawn time and tells the agent which mode to use.
The agent also uses a worktree if told, or able to see, that another writer is active.
Work in another repository and risky destructive git still require a worktree.

Any value other than `branch`, including an empty result, means `worktree`.
An empty result can occur when the config library cannot load from inside a `workspace/<name>` clone.

Branch mode requires these checks and cleanup:

1. Run `git status --porcelain --untracked-files=no` before switching branches.
   Dirty means tracked files with uncommitted changes or staged changes. Untracked files do not count.
2. Refuse to switch branches when dirty and say why.
3. Before each commit in `branch` mode, check that HEAD is still your ticket branch with `git branch --show-current`.
   Stop if HEAD is no longer your ticket branch.
4. After merge in `branch` mode, return to the base branch and delete the local ticket branch.
5. Always tell the user the branch name.

Harness `isolation` option behaviour is outside this change's scope.

## Consequences

- Adopters who do nothing keep worktree isolation.
- `branch` permits foreground builds in the local copy when no other writer is active and tracked files are clean.
- Background builds and builds overlapping known active writers use worktrees, including agents still working from earlier spawns.
- The setting does not prevent a collision the orchestrator did not detect.
- The HEAD check stops a commit when the agent detects another branch. It provides no checkout lock or atomic collision prevention.
- Branch cleanup returns the local copy to its base branch after merge.
- Static tests pin the documentation contract. Config tests check defaults and overrides. Neither enforces agent behaviour.

## Artifacts

- `.claude/project-config.defaults.json` — `build.isolation`
- `.claude/rules/isolated-builds.md`
- `.claude/skills/fan-out/SKILL.md`
- `.claude/agents/{backend,frontend,platform,data}-engineer.md`
- `.claude/agents/{product-manager,ui-designer,ux-designer}.md`
- `docs/project-config.md`
- `.claude/hooks/tests/test_config_build_isolation.sh`

## Architecture evolution

### Before

Spawned build agents always preferred `isolation: "worktree"`.
There was no ops-fork setting for local branch builds.

### After

`worktree` remains the default.
The orchestrator can select `branch` for a foreground build with no other active writer on the local copy.
Tracked files must be clean before switching branches.
Background builds, concurrent writers, another repository, and risky destructive git still require worktrees.
The agent checks HEAD before each commit and reports its branch name.

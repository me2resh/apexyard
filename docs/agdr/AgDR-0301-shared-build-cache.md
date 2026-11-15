---
id: AgDR-0301
timestamp: 2026-11-15T12:00:00Z
agent: platform-engineer
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# AgDR-0301: Share one build cache across worktrees through an opt-out env script

> In the context of disk growth from per-worktree dependency and build copies (me2resh/apexyard#2070 step 2), facing the need to share caches without a hook change, I decided to add `bin/apexyard-build-env`, which prints exports for one shared cache, to accept that installed folders stay per worktree.

## Context

Each worktree builds its own copy of the same dependencies. One machine reached 15 GB or more of build output.
Step 2 of #2070 asks for one shared build folder and one package store, with no hook change.
Isolated builds (`.claude/rules/isolated-builds.md`) and parallel writers must keep working.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A - Env script that prints exports (chosen) | No hook change. Opt-out. Each tool uses its own safe sharing. Easy to test. | The user or agent must run it. |
| B - Symlink `node_modules` and `target` between worktrees | Saves most space. | Two writers can corrupt one tree. Branches with different lockfiles break each other. |
| C - Set variables in a hook | Automatic. | Changes a hook. Out of scope for step 2. |

## Decision

Choose **Option A**.
The script shares package caches (npm, pnpm, yarn, pip, Go) and one cargo build folder for each repo.
The repo key is the repo name plus a hash of the git common dir, so repos never share a folder.
It keeps variables the user already set. It writes nothing. A bad path stops it with exit 2.
Opt out with `APEXYARD_BUILD_CACHE=off` or `build.cache.enabled: false`.
Set the folder with `build.cache.dir` or `APEXYARD_BUILD_CACHE=<absolute path>`.

## Consequences

- Package downloads and compiled crates are stored once per machine, not once per worktree.
- pnpm hard-links from the shared store, so `node_modules` of each worktree uses little space.
- Cargo serializes builds of one repo on its folder lock. Results stay correct.
- `node_modules` stays per worktree. Full sharing needs a later decision.
- Clean-up of the shared folder is out of scope here. Steps 4 and 5 of #2070 cover disk budget and reporting.

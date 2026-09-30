# Isolated Builds — Safe-by-Default Multi-Repo Git

Multi-repo / portfolio work regularly needs to build a repo other than the one the agent's cwd governs — a sibling managed repo, a premium component, a scratch experiment. The common shortcut is `git clone /tmp/<name> && cd /tmp/<name>`. This rule is the **trigger heuristic** — it defines the safe pattern for that class of work and the two failure modes that make the shortcut dangerous.

The two failure modes are mechanical, not hypothetical:

1. **`/tmp` clones get cleaned mid-session.** The OS (or a stray `rm -rf /tmp/*`) can vanish the directory out from under a long-running agent turn. The next command in the same bash block then runs somewhere else entirely.
2. **A `cd` without `|| exit 1` fails silently.** If the target directory is gone or mistyped, `cd` prints an error to stderr but the shell **keeps going** in the original directory. The next command in the chain — including a `git reset --hard` — then runs in whatever repo the agent started in, not the one it meant to build. This is exactly how an ops fork gets corrupted: a vanished `/tmp` clone, a silent `cd` failure, and a hard reset that lands on the fork's own branch instead.

## When to use an isolated build (proactively)

Heuristic: reach for an isolated build whenever the task is **any** of these:

- **Building or testing a sibling/managed repo** while the current cwd is the ops fork or a different project
- **Running destructive git** (`reset --hard`, `clean -fd`, force operations) as part of a build/verify cycle, where a wrong-repo execution would be costly
- **Spawning a build-class sub-agent in `worktree` mode** via the `Agent` tool for implementation work (backend/frontend/platform engineer, etc.) — see "Standard for spawned build agents" below

## The safe pattern

- **Use `git worktree add` off the fork's own clone, never `/tmp`.** A worktree is a linked working directory sharing one repo's `.git` — isolation without a second clone.
- **One location convention, no exceptions: `.claude/worktrees/<type>-<ticket>-<short-slug>`.** This is the same root the harness already uses for `Agent(isolation: "worktree")` spawns (`.claude/worktrees/agent-<id>`), it's already gitignored, and it never appears as a sibling of the fork root cluttering the editor's file tree or reading as a second repo. Hand-created worktrees join that one location instead of inventing a new one. `<type>` is the branch type (`fix`, `feature`, `chore`, `docs`, …), `<ticket>` is the tracker ID, `<short-slug>` is a few words of context — e.g. `.claude/worktrees/fix-1024-worktree-hygiene`. A worktree named this way is legible months later without opening it.
- **Always `cd <dir> || exit 1` in any dir-changing bash block.** A missing or mistyped path must abort the block, not silently continue in the wrong directory. Never chain a bare `cd <dir> &&` — the `|| exit 1` (or equivalent early-return) is not optional ceremony, it's the one line that turns a silent wrong-repo failure into a loud stop.
- **Never `git reset --hard` (or other destructive git) without first confirming the repo.** Run `git rev-parse --show-toplevel` and check the result names the repo you intend to reset — a bare eyeball check, not a formal ceremony — before any hard reset, forced clean, or forced checkout.

```bash
# WRONG — silent wrong-repo risk, AND a stray sibling-of-fork-root worktree
cd /tmp/sibling-repo
git reset --hard origin/main   # if the cd silently failed, this just reset the ops fork

# RIGHT — worktree under .claude/worktrees/, ticket-tied name, guarded cd, confirmed toplevel
git worktree add .claude/worktrees/fix-1024-worktree-hygiene -b fix/GH-1024-worktree-hygiene main
cd .claude/worktrees/fix-1024-worktree-hygiene || exit 1
[ "$(git rev-parse --show-toplevel)" = "$(pwd)" ] || { echo "wrong repo, aborting"; exit 1; }
git reset --hard origin/main
```

For a genuinely separate repo (not this one) that still needs a persistent, non-`/tmp` home — a sibling managed project, a premium component — clone it once to a durable path you control (e.g. `workspace/<name>/`, per the portfolio model) and create required worktrees from that clone under `.claude/worktrees/<type>-<ticket>-<short-slug>`.
A managed project's `workspace/<name>` clone counts as "the local copy" for that project.
`branch` mode can apply when that clone is the current repository and the conditions below hold.

## Lifecycle — remove the worktree once its PR merges

A worktree is scoped to the ticket it was created for, not kept around after. Once the PR merges:

```bash
git worktree remove .claude/worktrees/fix-1024-worktree-hygiene
```

The agent that merges the PR is the one that removes the worktree — the same turn, not a follow-up. This is what keeps `.claude/worktrees/` from accumulating stale checkouts the way the sibling-of-fork-root directories did: nothing prunes those automatically, and `git worktree prune` only clears registry entries whose *directory* is already gone — it does nothing for a worktree that still exists on disk with a long-merged branch. If a squash-merge model is in play, don't use `git branch --merged` / `--is-ancestor` to decide "is this done" — a squashed branch's tip is never an ancestor of the base. Check the PR's actual state (`gh pr view <N> --json state,mergedAt`) instead.

## Build isolation setting (`build.isolation`)

The setting applies to the whole ops fork, not per project.
Read `build.isolation` before creating a ticket branch or spawning a build agent:

```bash
isolation=$(
  . "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh" &&
    config_get_or '.build.isolation' 'worktree'
) || isolation=worktree
[ "$isolation" = branch ] || isolation=worktree
```

Any value other than `branch`, including an empty result, means `worktree`.
An empty result can occur when the config library cannot load from inside a `workspace/<name>` clone.

| Value | When to use it | Behaviour |
|-------|----------------|-----------|
| `worktree` (default) | Default for build spawns | Create `.claude/worktrees/<type>-<ticket>-<short-slug>` or pass `isolation: "worktree"` to the Agent tool. Tell the user the worktree path and how to test the change. |
| `branch` | Foreground build spawn with no other active writer on the local copy | Create the ticket branch in the local copy (`git checkout -b …`). Apply the checks below. |

`branch` mode applies only to a foreground build spawn when no other writer is active on that checkout.
A background build spawn always uses a worktree, regardless of `build.isolation`.
Any build spawn while another writer is active on that checkout uses a worktree, regardless of `build.isolation`.
Parallel means overlapping writers, including a build agent still working from an earlier spawn.
The orchestrator decides the mode at spawn time and tells the agent which mode to use.
This includes concurrent `/fan-out` and Workflow writers.
The setting does not prevent a collision the orchestrator did not detect.

**Branch checks and lifecycle:**

- Run `git status --porcelain --untracked-files=no` before switching branches.
  Dirty means tracked files with uncommitted changes or staged changes. Untracked files do not count.
- Refuse to switch branches when dirty and say why.
  Wait until tracked changes are resolved or the operator chooses a worktree.
- Before each commit in `branch` mode, check that HEAD is still your ticket branch with `git branch --show-current`.
  Stop if HEAD is no longer your ticket branch.
- After merge in `branch` mode, return to the base branch and delete the local ticket branch.
- Always tell the user the branch name, in either mode.

**Other cases that still need a worktree** (even when the setting is `branch`):

- The work is in a different repository from the current one
- The work uses destructive git where a mistake in the local copy costs too much

Override the default in `.claude/project-config.json`:

```json
{ "build": { "isolation": "branch" } }
```

See `docs/project-config.md` and AgDR-0210.

## Standard for spawned build agents

The orchestrator reads `build.isolation` and checks concurrency before each spawn.
The spawn prompt must name the selected mode.

- **`worktree` mode (default):** pass `isolation: "worktree"` for spawned build-class agents.
  This covers backend, frontend, platform, and data engineers, product managers, UI designers, and UX designers.
  The harness creates a worktree under `.claude/worktrees/agent-<id>`.
- **`branch` mode:** spawn in the foreground without worktree isolation only when no other writer is active on that checkout.
  Instruct the agent to follow the branch checks and lifecycle above.
- **Background or concurrent writers:** always pass `isolation: "worktree"`, regardless of the setting.
  Check for build agents still working from earlier spawns, including those outside `/fan-out` or Workflows.
- **Agent second guard:** if you are told or can see that another writer is active, use a worktree.

## When NOT to bother

- **Single read-only inspection** of another repo (`git -C <path> log`, a one-off `git show`) — no build, no destructive git, no isolation needed.
- **Working directly on the current repo's checkout in `branch` mode** — when `build.isolation` is `branch`, a foreground build with no other active writer creates the ticket branch in the local copy. Tracked files must have no uncommitted or staged changes. Branch-naming hygiene is still covered by `git-conventions.md`. If a worktree is warranted (parallel work, dirty tree, other repo, destructive git, or `worktree` mode), the `.claude/worktrees/<type>-<ticket>-<short-slug>` location convention above still applies.

## Self-check before responding

Before running a bash block that changes directory into another repo or clone, scan your planned commands for:

```
[ ] Is the target directory a persistent clone/worktree, not /tmp?
[ ] If it's a hand-created worktree, does it live under `.claude/worktrees/<type>-<ticket>-<short-slug>`?
[ ] Does every `cd <dir>` in this block end in `|| exit 1` (or equivalent)?
[ ] Before any `git reset --hard` / forced clean / forced checkout, did I confirm `git rev-parse --show-toplevel` names the intended repo?
[ ] Did I read `build.isolation` (default `worktree`) before choosing branch vs worktree?
[ ] If `branch` mode, did I check tracked changes with `git status --porcelain --untracked-files=no` and refuse when dirty?
[ ] Before each commit in `branch` mode, did I check that HEAD is still my ticket branch?
[ ] Did the orchestrator choose the mode at spawn time and tell the agent?
[ ] If the build spawn is background or another writer is active on that checkout, did I use a worktree?
[ ] If this is a spawned build agent in `worktree` mode, did I pass `isolation: "worktree"`?
[ ] Did I always tell the user the branch name?
[ ] If I created a worktree, did I tell the user the path and how to test?
[ ] After merge in `worktree` mode, did I `git worktree remove` it?
[ ] After merge in `branch` mode, did I return to the base branch and delete the local ticket branch?
```

If any box is unchecked and the block runs destructive git or a build, fix it before running — not after.

## Backstop

This rule is **primarily self-discipline**. Mechanical enforcement isn't fully viable — a shell hook can't reliably tell "this `cd` target is a persistent worktree" from "this `cd` target is a `/tmp` clone that happens to still exist right now," and it can't know which repo the agent *intended* to reset. Where a cheap, non-blocking signal is possible (a `git reset --hard` command, a `cd /tmp/...` build pattern), an advisory PreToolUse hook can nudge — same shape as `check-upstream-drift.sh` — but the hook is a backstop, not the primary defense.

The cost of using a persistent worktree and a guarded `cd` is a few extra lines. The cost of a silently-failed `cd` followed by a hard reset is a corrupted ops fork and lost uncommitted work.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

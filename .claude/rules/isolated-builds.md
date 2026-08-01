# Isolated Builds — Safe-by-Default Multi-Repo Git

Multi-repo / portfolio work regularly needs to build a repo other than the one the agent's cwd governs — a sibling managed repo, a premium component, a scratch experiment. The common shortcut is `git clone /tmp/<name> && cd /tmp/<name>`. This rule is the **trigger heuristic** — it defines the safe pattern for that class of work and the two failure modes that make the shortcut dangerous.

The two failure modes are mechanical, not hypothetical:

1. **`/tmp` clones get cleaned mid-session.** The OS (or a stray `rm -rf /tmp/*`) can vanish the directory out from under a long-running agent turn. The next command in the same bash block then runs somewhere else entirely.
2. **A `cd` without `|| exit 1` fails silently.** If the target directory is gone or mistyped, `cd` prints an error to stderr but the shell **keeps going** in the original directory. The next command in the chain — including a `git reset --hard` — then runs in whatever repo the agent started in, not the one it meant to build. This is exactly how an ops fork gets corrupted: a vanished `/tmp` clone, a silent `cd` failure, and a hard reset that lands on the fork's own branch instead.

## When to use an isolated build (proactively)

Heuristic: reach for an isolated build whenever the task is **any** of these:

- **Building or testing a sibling/managed repo** while the current cwd is the ops fork or a different project
- **Running destructive git** (`reset --hard`, `clean -fd`, force operations) as part of a build/verify cycle, where a wrong-repo execution would be costly
- **Spawning a build-class sub-agent** via the `Agent` tool for implementation work (backend/frontend/platform engineer, etc.) — see "Standard for spawned build agents" below

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

For a genuinely separate repo (not this one) that still needs a persistent, non-`/tmp` home — a sibling managed project, a premium component — clone it once to a durable path you control (e.g. `workspace/<name>/`, per the portfolio model) and worktree off *that* clone using the same `.claude/worktrees/<type>-<ticket>-<short-slug>` convention inside it.

## Lifecycle — remove the worktree once its PR merges

A worktree is scoped to the ticket it was created for, not kept around after. Once the PR merges:

```bash
git worktree remove .claude/worktrees/fix-1024-worktree-hygiene
```

The agent that merges the PR is the one that removes the worktree — the same turn, not a follow-up. This is what keeps `.claude/worktrees/` from accumulating stale checkouts the way the sibling-of-fork-root directories did: nothing prunes those automatically, and `git worktree prune` only clears registry entries whose *directory* is already gone — it does nothing for a worktree that still exists on disk with a long-merged branch. If a squash-merge model is in play, don't use `git branch --merged` / `--is-ancestor` to decide "is this done" — a squashed branch's tip is never an ancestor of the base. Check the PR's actual state (`gh pr view <N> --json state,mergedAt`) instead.

## Standard for spawned build agents

The `Agent` tool's `isolation: "worktree"` option is the standard for spawned build-class agents (backend-engineer, frontend-engineer, platform-engineer, and similar). It creates a temporary git worktree under `.claude/worktrees/agent-<id>` so the sub-agent works on an isolated copy of the repo — the same location convention and safety property this rule asks for by hand, provided and cleaned up automatically. Prefer `isolation: "worktree"` over asking a sub-agent to `cd` into a manually managed clone whenever the harness supports it.

## When NOT to bother

- **Single read-only inspection** of another repo (`git -C <path> log`, a one-off `git show`) — no build, no destructive git, no isolation needed.
- **Working directly on the current repo's checkout with no destructive git and no build isolation need** — this rule's failure-mode reasoning is about *other* repos and about any hand-created worktree; the current repo's own branch-naming hygiene is covered by `git-conventions.md`. If a worktree is warranted at all (a build, a sub-agent spawn, a destructive-git step), the `.claude/worktrees/<type>-<ticket>-<short-slug>` location convention above still applies even when the worktree is of this same repo.

## Self-check before responding

Before running a bash block that changes directory into another repo or clone, scan your planned commands for:

```
[ ] Is the target directory a persistent clone/worktree, not /tmp?
[ ] If it's a hand-created worktree, does it live under `.claude/worktrees/<type>-<ticket>-<short-slug>`?
[ ] Does every `cd <dir>` in this block end in `|| exit 1` (or equivalent)?
[ ] Before any `git reset --hard` / forced clean / forced checkout, did I confirm `git rev-parse --show-toplevel` names the intended repo?
[ ] If this is a spawned build agent, did I pass `isolation: "worktree"`?
[ ] Once this ticket's PR merges, did I `git worktree remove` it?
```

If any box is unchecked and the block runs destructive git or a build, fix it before running — not after.

## Backstop

This rule is **primarily self-discipline**. Mechanical enforcement isn't fully viable — a shell hook can't reliably tell "this `cd` target is a persistent worktree" from "this `cd` target is a `/tmp` clone that happens to still exist right now," and it can't know which repo the agent *intended* to reset. Where a cheap, non-blocking signal is possible (a `git reset --hard` command, a `cd /tmp/...` build pattern), an advisory PreToolUse hook can nudge — same shape as `check-upstream-drift.sh` — but the hook is a backstop, not the primary defense.

The cost of using a persistent worktree and a guarded `cd` is a few extra lines. The cost of a silently-failed `cd` followed by a hard reset is a corrupted ops fork and lost uncommitted work.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

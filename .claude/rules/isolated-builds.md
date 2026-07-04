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

- **Use `git worktree add` off a persistent clone, never `/tmp`.** A worktree is a linked working directory sharing one repo's `.git` — isolation without a second clone, and it lives at a path you control and that survives the session (e.g. `workspace/<name>/` or a dedicated `~/repos/<name>` clone, not `/tmp/...`).
- **Always `cd <dir> || exit 1` in any dir-changing bash block.** A missing or mistyped path must abort the block, not silently continue in the wrong directory. Never chain a bare `cd <dir> &&` — the `|| exit 1` (or equivalent early-return) is not optional ceremony, it's the one line that turns a silent wrong-repo failure into a loud stop.
- **Never `git reset --hard` (or other destructive git) without first confirming the repo.** Run `git rev-parse --show-toplevel` and check the result names the repo you intend to reset — a bare eyeball check, not a formal ceremony — before any hard reset, forced clean, or forced checkout.

```bash
# WRONG — silent wrong-repo risk
cd /tmp/sibling-repo
git reset --hard origin/main   # if the cd silently failed, this just reset the ops fork

# RIGHT — persistent clone, worktree, guarded cd, confirmed toplevel
git -C ~/repos/sibling-repo worktree add ../sibling-repo-build main
cd ~/repos/sibling-repo-build || exit 1
[ "$(git rev-parse --show-toplevel)" = "$HOME/repos/sibling-repo-build" ] || { echo "wrong repo, aborting"; exit 1; }
git reset --hard origin/main
```

## Standard for spawned build agents

The `Agent` tool's `isolation: "worktree"` option is the standard for spawned build-class agents (backend-engineer, frontend-engineer, platform-engineer, and similar). It creates a temporary git worktree so the sub-agent works on an isolated copy of the repo — the same safety property this rule asks for by hand, provided automatically. Prefer `isolation: "worktree"` over asking a sub-agent to `cd` into a manually managed clone whenever the harness supports it.

## When NOT to bother

- **Single read-only inspection** of another repo (`git -C <path> log`, a one-off `git show`) — no build, no destructive git, no isolation needed.
- **Work entirely inside the current repo** — this rule is about *other* repos; the current repo's own branch/worktree hygiene is covered by `git-conventions.md`.

## Self-check before responding

Before running a bash block that changes directory into another repo or clone, scan your planned commands for:

```
[ ] Is the target directory a persistent clone/worktree, not /tmp?
[ ] Does every `cd <dir>` in this block end in `|| exit 1` (or equivalent)?
[ ] Before any `git reset --hard` / forced clean / forced checkout, did I confirm `git rev-parse --show-toplevel` names the intended repo?
[ ] If this is a spawned build agent, did I pass `isolation: "worktree"`?
```

If any box is unchecked and the block runs destructive git or a build, fix it before running — not after.

## Backstop

This rule is **primarily self-discipline**. Mechanical enforcement isn't fully viable — a shell hook can't reliably tell "this `cd` target is a persistent worktree" from "this `cd` target is a `/tmp` clone that happens to still exist right now," and it can't know which repo the agent *intended* to reset. Where a cheap, non-blocking signal is possible (a `git reset --hard` command, a `cd /tmp/...` build pattern), an advisory PreToolUse hook can nudge — same shape as `check-upstream-drift.sh` — but the hook is a backstop, not the primary defense.

The cost of using a persistent worktree and a guarded `cd` is a few extra lines. The cost of a silently-failed `cd` followed by a hard reset is a corrupted ops fork and lost uncommitted work.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

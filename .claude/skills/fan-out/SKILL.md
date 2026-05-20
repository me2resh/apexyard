---
name: fan-out
description: Spawn N parallel Agent calls in one message (per-task agent type, worktree isolation, background mode).
disable-model-invocation: false
argument-hint: "<task1, task2, ...> | <path/to/tasks.md> | --from-tickets <ref1,ref2,...>"
effort: medium
---

# /fan-out — Parallel Agent Fan-Out

Spawns multiple specialised agents in parallel — each on its own task, optionally in its own git worktree — so independent work items progress concurrently instead of being silently serialised behind a single agent's session.

This skill is the **happy path** for parallel execution. The companion rule [`.claude/rules/parallel-work.md`](../../rules/parallel-work.md) defines **when** to *offer* fan-out proactively. Read both before invoking.

## When to use

The trigger heuristic is in [`parallel-work.md`](../../rules/parallel-work.md). The short version: use `/fan-out` when the user's request decomposes into ≥ 2 work items that are file-independent, context-independent, and individually substantial.

Do NOT use when:

- Tasks share file write targets (worktree merge-back will conflict)
- One task's output is another's input (sequential dependency)
- The work is a single indivisible task
- The decision itself is the work (architecture / AgDR-class) — that needs cross-task reasoning, not concurrency

## Process

### 1. Gather tasks

Accept tasks from any of these forms:

- `$ARGUMENTS` as a comma-separated list: `"audit hooks dir, audit skills dir, audit rules dir"`
- A markdown file path: `/fan-out tasks.md` — one task per line, blank lines and `#` comments ignored
- `--from-tickets <list>`: `/fan-out --from-tickets apexyard#109,apexyard#110,apexyard#111` — fetch each issue title + body via `gh issue view` and use them as task descriptions
- Interactive entry — if `$ARGUMENTS` is empty, prompt: *"Paste your tasks, one per line. Blank line to finish."*

Trim whitespace, drop empties. If the result is fewer than 2 tasks, stop: fan-out is overkill for one item.

### 2. Per-task questions — ASK ONCE per task

For each task, infer the answer from the description first, then ask only when ambiguous.

**Agent type** — default `general-purpose`. Options:

| Agent | Use for |
|-------|---------|
| `general-purpose` | Implementation, multi-step research, anything mixed |
| `Explore` | Read-only research, codebase questions, audits |
| `code-reviewer` | Reviewing an existing PR (read-only) |
| `security-reviewer` | Security audit of a PR (read-only) |
| `Plan` | Plan-mode — produces a plan, no edits |
| Custom | Any subagent in `.claude/agents/` |

If a task obviously needs editing (verbs like *implement*, *add*, *fix*, *refactor*, *migrate*, *write*), reject any read-only agent type and suggest `general-purpose`.

**Isolation** — default `worktree` if any agent will write code; `shared` if all agents are read-only research. Infer from the task verb. Ask only when ambiguous.

**Mode** — default `foreground` (≤ 2-minute estimated runtime); `background` if estimated > 2 minutes. Estimate from task scope (single-file edit ≈ short; cross-cutting refactor ≈ long; full audit ≈ long). Ask only when ambiguous.

### 3. Active-ticket safety check

For every task that involves code edits (not pure research), verify a ticket marker exists:

- Per-project: `<ops_root>/.claude/session/tickets/<project>` if the task targets a managed project's `workspace/<name>/`
- Fallback: `<ops_root>/.claude/session/current-ticket` for ops-fork edits

If missing, **refuse the entire fan-out** and tell the user:

```
Cannot fan out — task "<task>" needs an active ticket. Run:
  /start-ticket <ref>
…then re-run /fan-out.
```

The `require-active-ticket.sh` hook would block edits anyway. Failing fast at fan-out time is kinder UX than letting 3 of 5 agents start, then 2 fail mid-run.

### 4. File-collision guard

Heuristically detect tasks that target the same file paths. Compare file paths mentioned in each task description (literal paths, glob patterns, or implied file scope).

If two or more tasks share write targets, **refuse parallel** and recommend serial:

```
Cannot fan out — these tasks share write targets:
  - Task 2: edits .claude/hooks/pre-push-gate.sh
  - Task 4: edits .claude/hooks/pre-push-gate.sh

Run them serially, or split task boundaries so each owns distinct files.
```

The alternative is `git` worktree merge conflicts on merge-back — recoverable but always painful.

### 5. Show the plan and confirm

Print a table:

```
| # | Task | Agent | Isolation | Mode |
|---|------|-------|-----------|------|
| 1 | …    | general-purpose | worktree | foreground |
| 2 | …    | Explore | shared | foreground |
…
```

Wait for the user's `yes` / `confirm` / `go` before spawning. Edits to the plan in this step are fine — re-print the table and re-ask.

### 6. Spawn — ALL CALLS IN A SINGLE ASSISTANT MESSAGE

This is the only step where parallelism actually happens. Emit a SINGLE assistant message containing N `Agent` tool calls (one per task). Looping `Agent` invocations across multiple messages serialises them — the second agent will not start until the first returns.

```
Spawning 4 agents in parallel…
[Agent call 1]
[Agent call 2]
[Agent call 3]
[Agent call 4]
```

Each agent's prompt must be **self-contained** — sub-agents do not inherit the parent's conversation context. Include in each prompt:

- The task description verbatim
- Any reference paths the agent needs to read
- The expected output format (what to return to the parent)
- Constraints inherited from the parent (e.g. "don't push", "use specific git add")

For tasks with `isolation: worktree`, pass `isolation: worktree` in the Agent call. For long-running tasks with `mode: background`, pass `run_in_background: true`.

### 7. Collect results

Foreground tasks return inline — wait for all of them. Background tasks return asynchronously — note their IDs and tell the user how to check on them later.

For each returned result, capture:

- Task ID
- Status (success / failure / partial)
- Branch name (if worktree was used)
- Summary of what the agent did
- Any follow-ups the agent flagged

### 8. Worktree merge-back

If any agents used `worktree` isolation, list the branches they created. Then offer to sequence the merge-back:

```
Worktree branches to merge:
  1. feature/#117-add-fan-out-skill        (agent 1)
  2. feature/#118-add-parallel-rule        (agent 2)
  3. fix/#120-bug-in-X                     (agent 3)

Merge back in order? [y/n/select]
```

For each branch in turn:

1. Switch to the branch (`git checkout`)
2. Rebase onto the latest base if needed
3. Optionally cherry-pick into the user's working branch
4. **Pause on conflict** — ask the user to resolve interactively. Do not auto-resolve.

Each project owns one merge-back attempt. If the user wants to skip a branch (e.g. open as its own PR instead), record that and continue.

### 9. Final report

```
Fan-out complete (N tasks, M succeeded, K background still running).

| # | Task | Status | Branch | Follow-ups |
|---|------|--------|--------|------------|
| 1 | …    | done   | …      | …          |
…

Background tasks running: <ids>. They'll surface results when done.
```

## Rules

1. **All `Agent` tool calls for a single fan-out MUST be in the SAME assistant message.** Multi-message loops do not get concurrency — they serialise. This is the most important rule in this skill.
2. **Use `isolation: worktree` whenever any agent will write code.** Required to prevent file-level races between agents sharing one working directory.
3. **Refuse fan-out when tasks share file write targets.** Serialise instead — the merge-back conflict cost outweighs any concurrency win.
4. **Refuse fan-out when tasks have sequential dependencies.** If task B reads task A's output, they cannot run in parallel.
5. **Cap at 5 concurrent agents per invocation.** If the user wants more, ask them to split into batches. Beyond 5, returns diminish (review fatigue, merge-back queue) and risk grows (rate limits, context dilution).
6. **Each agent's prompt must be self-contained** — sub-agents do not see the parent conversation. Include task description, reference paths, expected output format, and any inherited constraints inline.
7. **Background mode only for >2-minute estimated work.** For short tasks, foreground is faster end-to-end (no async overhead).
8. **Refuse a read-only agent type for an editing task.** `Explore`, `code-reviewer`, `security-reviewer`, and `Plan` cannot write. If the task verb says "implement" / "fix" / "add" / "refactor", suggest `general-purpose`.
9. **Active-ticket check happens at step 3, not step 6.** Failing at plan-time is kinder than failing mid-spawn.
10. **Pause on merge-back conflict — never auto-resolve.** The user owns the merge.

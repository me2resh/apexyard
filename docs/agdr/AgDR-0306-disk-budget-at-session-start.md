---
id: AgDR-0306
timestamp: 2026-11-15T12:00:00Z
agent: claude
model: claude-opus-5-5
session: n/a
trigger: user-prompt
status: executed
category: architecture
---

# Disk budget at session start, with a sweep that the user approves

> In the context of ApexYard folders that grew to about 113 GB on one machine, facing a full disk that stops all work, we decided to add an advisory SessionStart check with a time limit and a separate sweep command that removes items only from a plan the user approved, and neglected an automatic sweep and a background measurement, to achieve a predictable disk budget with no surprise removals, accepting that a slow disk can skip the size check and that the user's yes is a process rule, not a mechanical gate.

## Context

- Issue me2resh/apexyard#2070 lists five steps. This record covers step 4, "Disk budget at session start".
- The owner set three limits: 10 GB of owned folders, 10% free disk space and 7 days of age. All three must be configurable.
- The session-start part must be fast and advisory. It must never remove anything and never block the session.
- The issue's safety rules apply:
  - Remove only what can be rebuilt, or what belongs to a merged or closed PR.
  - Never remove a worktree that has uncommitted or unpushed work.
  - Keep a removal log and offer a dry run.
  - Never weaken a gate. Never use `--force` on a git worktree.
- Step 3 (a separate PR) adds a small record per review copy under one known folder. This step must use that record when it exists and stay safe when it does not.
- Gate hardening is frozen (AgDR-0267). This step adds no gate and changes no gate.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) SessionStart measures and removes old copies automatically | No user action. | Removes files with no review. It breaks the "remove only after the user says yes" rule. |
| (b) SessionStart measures in the background and reports in the next session | Never slows the session. | A detached process outlives the hook. The first session reports nothing. More moving parts. |
| (c) SessionStart measures with a time limit and a 6-hour cache, then proposes. A separate command makes a dry-run plan and applies only that plan. | Fast and bounded. Advisory only. The user sees the exact list before any removal. | A very slow disk skips the size check. The free-space check still runs. |

## Decision

Option (c).

- `.claude/hooks/check-disk-budget.sh` runs at SessionStart through the dispatcher. It does not run after compaction.
  - It measures the owned folders with `du`, under `measure_timeout_seconds` (default 3).
  - It caches a good result for 6 hours in `.claude/session/disk-budget-size`.
  - It reads free space with `df`, under a 2-second limit.
  - When a limit is exceeded, it prints a proposal. It tells the agent to show the dry-run list and to remove nothing until the user says yes.
  - Every exit path exits 0. It contains no removal command.
- Owned folders: `<ops>/.claude/worktrees`, `<workspace>/*.worktrees`, `<workspace>/*/.claude/worktrees`, `<ops>/.claude/session`, each `review_copy_roots` entry and each `extra_paths` entry.
- `bin/apexyard-disk-sweep.sh` is the only part that removes.
  - The default run is a dry run. It lists each item to remove and each item to keep, with the reason. It saves a plan under `.claude/session/disk-sweep/`.
  - `--apply <plan-id>` checks each planned item again and removes only the items that still qualify. A plan expires after 24 hours and runs once.
  - Each result goes to `.claude/session/disk-sweep/removed.log`.
- The sweep looks only at direct children of the worktree folders and the review-copy roots. A root that is `/`, `HOME`, the ops root or the workspace folder is never used.
- An item qualifies only when all of these are true:
  - It is a real folder and not the current folder.
  - It has no uncommitted or untracked changes.
  - It is not locked, and no live or unknown session owns it (AgDR-0284).
  - Its age is `sweep_min_age_days` or more.
  - Its PR is MERGED or CLOSED. An unknown state keeps the item.
  - Its HEAD is on a remote, equals the PR head, or is an ancestor of the PR head.
- A linked worktree is removed with `git worktree remove`, never with `--force`. A review-copy clone is removed with `rm` only when its parent is a review-copy root and it has a review-copy record.
- The sweep reads the review-copy record that step 3 defines (AgDR-0305, `review-copy.sh`).
  - The record is `<git-dir>/apexyard-review-copy.json`, for example `<copy>/.git/apexyard-review-copy.json`.
  - The sweep reads `repo`, `pr`, `head_sha` and `created_at`. When `repo` has no owner, the owner comes from the copy's origin URL.
  - A HEAD equal to `head_sha` came from the forge, so it does not count as unpushed work.
  - With no record, a linked worktree uses its branch name and git admin file times. Any other copy is kept.
- Review-copy roots: the root of `review-copy.sh` is always included. That root is `$APEXYARD_REVIEW_COPY_ROOT`, else `<physical TMPDIR>/apexyard-review-copies`. `review_copy_roots` adds more roots.
- `.claude/project-config.defaults.json` ships `disk_budget` with `max_owned_gb` 10, `min_free_percent` 10, `sweep_min_age_days` 7, `measure_timeout_seconds` 3, `review_copy_roots` (empty) and `extra_paths` (empty).

## Consequences

- A session on a full machine sees one proposal line. The agent then shows the dry-run list and asks the user.
- The user's yes is a process rule. Nothing mechanical stops an agent that runs `--apply` without asking. The plan id ties the removal to a list that a dry run printed.
- A disk that is slower than the time limit skips the size check. The free-space check still runs, and `--measure` gives the full sizes with no limit.
- The 6-hour cache can show an old size after a manual removal. `--apply` deletes the cache.
- PR lookups use `gh`. With another tracker kind, every item is kept and the dry run says why.
- Build output inside a qualifying worktree goes with the worktree. Shared build caches from step 2 can go in `extra_paths` for measurement only.

## Artifacts

- Ticket: me2resh/apexyard#2070 (step 4)
- Files: `.claude/hooks/_lib-disk-budget.sh`, `.claude/hooks/check-disk-budget.sh`, `bin/apexyard-disk-sweep.sh`, `.claude/hooks/tests/test_disk_budget.sh`

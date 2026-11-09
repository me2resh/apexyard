# AgDR-0292 - Human Review Queue

**Status:** Accepted
**Date:** 2026-11-09
**Ticket:** me2resh/apexyard#1995
**Author:** Platform Engineer (Adel)

## Context

Rex-approved PRs accumulate while the operator focuses on building.
The merge gate is correct - it blocks an un-approved merge - but no surface told
the operator how many PRs were waiting, or slowed spawn points when the queue
grew large. Operators lost track of review debt, which delayed shipping.

The goal: show waiting human approvals in `/inbox`, `/status --briefing`, and
`apexyard status`, and optionally slow (or stop) new work when the queue is full.

## Options Considered

**Option A - New blocking hook at build-agent spawn.**
Add a `PreToolUse` hook that blocks every `Agent` call when the queue is full.
Rejected: AgDR-0267 freezes gate hardening. A new blocking hook changes what
existing gates block, violating that freeze.

**Option B - Rex markers plus thin tracker helper; warn by default.**
Count PRs from existing Rex markers (SHA prefix match against live open PR
heads). Add `tracker_open_pr_heads` to `_lib-tracker.sh`. Surfaces: briefing
line, inbox header, skill and rule text at spawn points. Default mode `warn`;
opt-in `refuse` for adopters who want harder enforcement.

Chosen. This adds no new blocking hook. Warn default leaves every existing gate
unchanged. Unknown tracker degrades gracefully to no-op.

**Option C - Count from gh pr list directly in each surface.**
Rejected: duplicates tracker-dispatch logic, breaks when tracker.kind is not gh.

## Decision

Implement Option B:

1. **Count algorithm.** A PR counts when a `*-rex.approved` marker exists whose
   first-line SHA equals the open PR head (prefix match for short SHAs) and no
   `*-ceo.approved` marker exists for the same PR. Count reads the tracker only
   through `tracker_open_pr_heads` in `_lib-tracker.sh`. Non-gh tracker kinds
   return 1; the queue degrades to unknown and never refuses.

2. **New library.** `_lib-review-queue.sh` owns `review_queue_line` (prints the
   waiting text, sets `REVIEW_QUEUE_COUNT`) and `review_queue_check` (warn or
   refuse based on config). No associative arrays; bash 3.2 compatible.

3. **Config.** `review_queue.limit` (default 4) and `review_queue.mode`
   (`warn` | `refuse`, default `warn`) in `project-config.defaults.json`.

4. **Briefing stays 4 lines.** The waiting text appends to the Role set line:
   `Role set: backend ; Waiting on you: N PRs, the oldest X hours`.

5. **Spawn points.** `bin/apexyard-start-ticket` calls `review_queue_check`
   before writing the marker. `/fan-out` SKILL.md and `isolated-builds.md`
   instruct the orchestrator to run the same check before spawning a build
   agent. No new hook fires; this is skill and rule text only.

6. **Gate hardening frozen.** No existing gate changes what it blocks (AgDR-0267).

## Consequences

- Operators see waiting approval debt in every briefing and inbox run.
- Default warn mode: no existing workflow breaks.
- Refuse mode: opt-in; operators who want hard enforcement set it explicitly.
- Unknown tracker (non-gh kind or CLI failure): always degrades to no-op.
- `test_status_briefing.sh` four-line pin: preserved - waiting text is on the
  same Role set line, not a new line.

## Artifacts

- `.claude/hooks/_lib-review-queue.sh` - new queue library
- `.claude/hooks/_lib-tracker.sh` - adds `tracker_open_pr_heads`
- `.claude/project-config.defaults.json` - adds `review_queue` block
- `.claude/skills/status/briefing.sh` - appends waiting suffix to Role set
- `.claude/skills/status/SKILL.md` - documents the new suffix
- `.claude/skills/inbox/SKILL.md` - adds review queue header section
- `bin/apexyard-start-ticket` - calls `review_queue_check` before marker write
- `.claude/skills/start-ticket/SKILL.md` - notes queue check
- `.claude/skills/fan-out/SKILL.md` - instructs queue check before spawn
- `.claude/rules/isolated-builds.md` - notes queue check before build-agent spawn
- `.claude/hooks/tests/test_review_queue.sh` - new test suite
- `docs/project-config.md` - documents `review_queue` keys
- `docs/architecture/apexyard-container.md` - evolution entry

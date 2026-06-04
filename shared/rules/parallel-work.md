# Parallel Work — When to Offer Fan-Out

ApexYard ships the `/fan-out` skill for spawning N parallel agents on independent tasks. The skill is the happy path; this rule is the **trigger heuristic** — it defines when an agent should *proactively offer* fan-out instead of executing work serially by default.

A typical session serialises tasks that don't need to be serial — N unrelated audits, N independent tickets, research across N unrelated areas. The framework should make parallel execution the default *offer* when it's safe, not a pattern each user rediscovers.

## When to OFFER parallel fan-out (proactively)

Heuristic: when the user's request decomposes into ≥ 2 work items that are all of:

- **File-independent** — different write targets, no shared edits
- **Context-independent** — one task's output does not feed another's input
- **Individually substantial** — ≥ 5 minutes of work each. Not "read 3 lines from 3 files" (overhead exceeds gain)

Examples that should trigger an offer:

- "Implement these 3 independent tickets" (each touches different code paths)
- "Audit hooks, skills, and rules for X" (3 unrelated codebase areas)
- "Add a hook for X, a skill for Y, and a rule for Z" (3 different files)
- "Research how libraries A, B, and C handle pagination" (3 unrelated reads)

## When NOT to fan out

- **Shared state or files** — two tasks edit the same file → serial. Worktree merge-back conflicts cost more than the concurrency win.
- **Sequential dependencies** — task B needs task A's output → serial.
- **Architecture / AgDR-class decisions** — the work IS the cross-task reasoning. Splitting it loses the shared context that makes a good decision possible.
- **Single large indivisible task** — e.g. "refactor module X from MVC to clean architecture". Splitting by file usually creates a sequential chain.
- **Trivial work** — three two-line edits. Spawning agents adds more overhead than it saves.

## How to offer

Short, explicit, non-pushy. Let the user pick:

```
These N items are independent — write targets don't overlap and outputs
don't chain. Want to fan them out via /fan-out (each on its own
worktree), or run serial?
```

If the user says yes → invoke `/fan-out`. If serial → proceed normally.

## Self-check before responding

Before answering a multi-item user request, scan your planned response for:

```
[ ] ≥ 2 work items in the response?
[ ] Are they file-independent?
[ ] Are they context-independent?
[ ] Are they each substantial (≥ 5 min)?
[ ] Did I OFFER /fan-out, or default-silently to serial?
```

If all four boxes are checked and you didn't offer fan-out, you missed a parallel-work opportunity.

## Backstop

This rule is **primarily self-discipline**. Mechanical enforcement isn't viable — no shell hook can see "the agent didn't propose parallel" in assistant prose. Pair this rule with feedback memory: if the CEO has previously asked "why didn't you fan this out?", surface the offer more aggressively next time.

The cost of offering fan-out and being told "no, just serial" is one sentence. The cost of silently serialising N independent items is N times the wall-clock latency the user notices.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

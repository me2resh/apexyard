# Loop Mode — When to Recommend a Closed Loop

A "loop" is a setup where you stop prompting an agent step-by-step and instead design a bounded cycle — discover → plan → execute → **verify** → iterate — that runs until a goal is met inside guardrails you set. The shift the field is naming ("design loops that prompt your agents, don't prompt steps") is real, but the durable lesson underneath it is narrower: **a loop is only as good as the skills it calls and its ability to check its own work, and it is only safe if it halts.**

This rule is the **trigger heuristic** — it defines when an agent should *proactively offer* (or, on opt-in, run) a closed loop instead of grinding through repetitive work one prompt at a time. It is the sibling of [`parallel-work.md`](parallel-work.md) (offer `/fan-out`) and [`plan-mode.md`](plan-mode.md) (enter plan mode). ApexYard is unusually well-suited to looping because it already ships the two things a loop needs and most setups lack: a library of **skills** (the 59 slash commands) and a real **eval layer** (Rex, the design/architecture reviews, CI, the merge gates, QA).

## When to OFFER loop mode (proactively)

Heuristic: offer a closed loop when the work is **all of**:

- **Repetitive over a set** — the same build→verify cycle applied to N items (per-view redesigns, "fix all the flaky tests", a bulk migration across modules, an audit across dimensions). Not a single bespoke change.
- **Machine-verifiable** — there is an eval the loop can run unattended to decide "done / not done": a build, a test suite, a typecheck, Rex, a count-reaches-target. A loop with no automatic verify is a confident-mistake machine.
- **Bounded** — a clear stopping condition (all items processed, count reached, N rounds dry) and a tolerable cost ceiling.

Examples that should trigger an offer:

- "Redesign all nine admin views to the new system" (N independent items, build+test+review as the eval)
- "Find and fix every place we still call the deprecated API" (loop-until-dry over a discoverable set)
- "Audit the codebase across these six security dimensions and verify each finding" (fan-out + adversarial verify)
- "Keep iterating on this migration until the test suite is green" (single-agent build→test→fix cycle)

## When NOT to loop

- **One-off or bespoke work** — a single feature, a judgement-heavy design call. The cycle ceremony costs more than it saves, and the cross-item reasoning that makes the call good is lost when you split it.
- **No automatic verify exists** — if "done" needs human eyes every iteration, you are the loop; a loop without a self-check just generates plausible-but-wrong output faster.
- **No stopping condition / unbounded cost** — open-ended exploration with no halt is the "ran forever" failure mode (and the budget surprise). Don't open a loop you can't close.
- **Shared-state or sequential work** — items that edit the same files or chain outputs; loop iterations will collide or starve. (Same constraint as `parallel-work.md`.)

## Which primitive

Match the loop shape to the tool:

- **Single-agent iterate on a cadence** → the harness `/loop` (self-paced "keep going until done") or `/schedule` (remote agent on a cron). Harness-owned; this rule governs *whether* to reach for them, not their mechanics.
- **N independent items, one pass each, in parallel** → [`/fan-out`](../skills/fan-out/SKILL.md) — worktree-isolated agent per item, file-collision guard, ticket pre-check. The list-of-tasks → merge-back shape.
- **A multi-stage fleet with a per-item verify gate** → the `Workflow` tool — pipelined phases (build → adversarially-verify → synthesize), loop-until-dry, budget-scaled fan-out. The structured-orchestration shape. Opt-in (it can spawn many agents); the user must ask for that scale.

## Guardrails (the loop must not run off a cliff)

Every loop you propose or run MUST state, up front:

- **Halt at the human gate.** A loop may build, test, and review, but it **MUST stop at the per-PR CEO merge gate and hand back** — it never self-approves a merge or writes its own approval marker. This is the load-bearing apexyard constraint; see [`pr-workflow.md`](pr-workflow.md) § "Plan-level 'go' is NOT merge approval".
- **Verify means build + tests + Rex — not just build.** A loop's eval stage must run the project's test suite (and lint/typecheck) in addition to the build, then a Rex pass. Skipping the test run is how a green build still ships broken behaviour — exactly what happened on the v3 view-redesign loop, where unverified agents left failing tests for cleanup afterward. This is *recommended discipline you build into the loop*: the framework only enforces it at the merge boundary (red-CI block + Rex review), not mid-iteration — so a loop that skips its own test step won't be stopped until the PR gate, by which point the cleanup cost has already landed.
- **A budget + iteration ceiling.** Set a max iteration count and a token/$ ceiling before starting; the loop halts at the ceiling. The expensive part of modern AI work is the loop, not the model — most of the job is making it stop.
- **No-progress detection.** Stop after K consecutive iterations that produce nothing new (loop-until-dry), rather than spinning.
- **Loops call skills, not re-derived prompts.** Inside the cycle, invoke apexyard's named skills (`/migration`, `/decide`, `/code-review`, …); a loop that re-derives everything each tick just burns budget.

## Self-check before responding

Before answering a request that involves repetitive multi-item work, scan your planned response for:

```
[ ] Is this the same build→verify cycle over ≥ 2 items?
[ ] Is there an automatic eval (build / tests / Rex / count) that decides "done"?
[ ] Is there a clear stopping condition and a cost ceiling?
[ ] Did I name the halt point (the CEO merge gate) and a verify stage that runs tests, not just build?
[ ] Did I pick the right primitive (/loop vs /fan-out vs Workflow), or default-silently to a serial grind?
```

If the first three boxes are checked and you didn't offer a loop, you missed an opportunity. If you offered one without naming the guardrails, you proposed a runaway.

## Backstop

This rule is **primarily self-discipline**. Mechanical enforcement isn't viable — no shell hook can see "the agent should have proposed a loop" in assistant prose, and the merge-gate hooks already stop a loop that tries to self-approve. Pair this rule with feedback memory: if the CEO has asked "why didn't you loop this?" or "why did that loop ship broken tests?", surface the offer — and the guardrails — more aggressively next time.

The cost of offering a loop and being told "no, just do it serially" is one sentence. The cost of grinding N near-identical items by hand is N times the latency the user notices — and the cost of running an *ungoverned* loop is a billing surprise and a pile of confident mistakes.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

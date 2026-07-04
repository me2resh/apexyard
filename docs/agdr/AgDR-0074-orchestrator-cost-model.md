# AgDR-0074 — Orchestrator cost model: in-thread persona adoption defeats the per-agent model matrix for in-flow work

> In the context of [AgDR-0050](AgDR-0050-agent-runtime-overhaul.md)'s per-agent model matrix (build engineers → `sonnet`, reviewers → `opus`, analysts → `haiku`), facing operator reports that the **main agent dominates token spend** despite that matrix, I decided to **document the structural tension** — the matrix only applies to *spawned* sub-agents, but AgDR-0050 § Axis 6 deliberately keeps *in-flow* work (implementation / PM / design) **in-thread**, so the bulk of work runs on the operator's primary tier (typically Opus) and the `sonnet` implementation default never takes effect — and to record the recommended cost levers (`opusplan`, a thin-orchestrator pattern, and populating `agent-routing.yaml`) rather than silently re-litigating the Axis-6 decision, to achieve a predictable + documented cost model for operators, accepting that the biggest single win (`opusplan`) is a harness-level operator choice the framework can recommend but not enforce.
>
> **Status**: ACCEPTED — documentation + frontmatter-conformance confirmation. Does not change the Axis-6 in-thread-vs-spawned split; it makes that split's cost consequence explicit and gives operators the levers to manage it.

**Metadata** — Status: ACCEPTED · Category: architecture · Supersedes: none · Related: [AgDR-0050](AgDR-0050-agent-runtime-overhaul.md) (agent runtime overhaul — the per-agent matrix + Axis 6 in-thread/spawned split), [AgDR-0068](AgDR-0068-governed-looping.md) (governed looping — the thin-orchestrator-as-loop-coordinator shape), [`.claude/rules/plan-mode.md`](../../.claude/rules/plan-mode.md) (`opusplan` prior art). (Body-H1 only, no YAML frontmatter — per the live convention; markdownlint MD025 trips on a YAML title + body H1 together.)

## Context

[AgDR-0050](AgDR-0050-agent-runtime-overhaul.md) shipped a 24-entry **per-agent model matrix** (Axis 2): Opus for depth-bound roles (Tech Lead, SRE, Pen Tester, Security Auditor, Code Reviewer), Sonnet for the implementation majority (Backend / Frontend / Platform / Data Engineer, Product Manager, designers), Haiku for checklist-shaped repeatable work (QA Engineer, Data Analyst). The intent was per-agent cost / quality optimisation — a QA AC-check shouldn't pay Opus prices, a build-engineer edit shouldn't pay the same rate as an architectural design.

The matrix is **real and correct** — but it has a structural blind spot that AgDR-0050 itself created and did not call out as a cost consequence.

AgDR-0050 § **Axis 6 (Hybrid, option C)** split role activations into two classes:

- **Isolated-work-class** roles (QA Engineer, Pen Tester, Data Analyst, the Heads-of-X, Security Auditor, Tech Lead reviews) — auto-triggers **spawn a sub-agent**. The sub-agent's `model:` frontmatter applies, so the matrix takes effect.
- **In-flow-class** roles (Backend Engineer, Frontend Engineer, Platform Engineer, Data Engineer, Product Manager, UI / UX Designer) — auto-triggers keep **in-thread persona adoption**, because spawning out-of-thread loses the shared "what just happened" context that ship-the-code flow depends on.

The model matrix is a property of a **spawned sub-agent's frontmatter**. In-thread persona adoption does not spawn anything — it injects the role file into the main thread, which keeps running on whatever model is driving the conversation (typically the operator's primary tier, Opus). So:

- **Reviews route correctly.** Rex (Code Reviewer) and Hakim (Security Auditor) are spawned → their `opus` frontmatter applies.
- **The bulk — implementation — does not.** Backend / Frontend Engineer work is adopted in-thread per Axis 6 → the `sonnet` default in their frontmatter is never consulted. Implementation, the highest-volume work in any SDLC, runs at the operator's primary tier.

The net effect operators observe: the main agent dominates token spend, and the matrix's cost optimisation appears not to work. It *does* work — but only on the spawned minority, not the in-thread majority. AgDR-0050 § Consequences mentioned "cost of running sub-agents vs in-thread persona adoption" as a *risk to the sub-agent approach*; it did not flag the inverse — that the in-thread approach defeats the matrix for the work that costs the most. This AgDR records that tension explicitly.

A compounding, separable issue: agent **frontmatter drift**. The matrix specifies `sonnet` for Backend + Frontend Engineer, but a working-tree drift had set those agent files to `model: opus` in some adopter forks — so even *spawning* a build engineer would not hit the cheap tier. (On the `dev` branch at the time of this AgDR the committed values were already `sonnet`, so this AgDR records the conformant state rather than editing the files; it documents the matrix-conformance check and points operators at `agent-routing.yaml` to pin the tiers so the drift can't recur silently.)

## Options Considered

### Axis A — Where to document the tension

| Option | Pros | Cons |
|--------|------|------|
| **A1. New AgDR referencing AgDR-0050** | Keeps AgDR-0050's accepted decision immutable; a clean, citable record of the *cost consequence* + levers; discoverable via `/agdr search cost` | One more file in the AgDR sequence |
| A2. Amend AgDR-0050 in place | Single source for everything about the runtime overhaul | Mutates an ACCEPTED cross-cutting AgDR that 10+ PRs reference; the cost tension is a *consequence*, not a *decision axis*, so it doesn't fit the option-matrix shape; harder to cite in isolation |

### Axis B — What to do about the in-flow cost

| Option | Pros | Cons |
|--------|------|------|
| **B1. Document levers, keep Axis 6 unchanged** | Preserves the Axis-6 shared-context benefit for in-flow work; operators opt into cost levers per their workload; biggest win (`opusplan`) needs no framework change | Cost optimisation is operator-driven, not automatic |
| B2. Flip in-flow roles to spawned sub-agents | Matrix applies automatically to implementation | Reverses Axis 6's load-bearing decision — loses shared context for ship-the-code flow, the exact failure mode Axis 6 chose against; spawning has cache-miss latency per invocation |
| B3. Force the main thread onto Sonnet | Cheapest default | Defeats the operator's choice of primary tier; bad default for planning / coordination, which genuinely benefits from Opus depth |

### Axis C — The recommended cost levers

Three levers, not mutually exclusive, ordered by effort-to-win ratio:

| Lever | Effort | Win |
|-------|--------|-----|
| **C1. `opusplan`** — Opus plans, Sonnet executes (harness model alias) | Zero framework change; one operator config | Largest single win — the high-volume *execution* phase drops to Sonnet while planning keeps Opus depth |
| **C2. Thin-orchestrator pattern** — keep the Opus loop as planner / coordinator; delegate well-scoped implementation to *spawned* `sonnet` build agents via `/fan-out` or `Workflow` | Operator workflow change; no framework change | Routes the in-flow majority through the matrix by *spawning* it, recovering the `sonnet` default for implementation while the coordinator stays Opus |
| **C3. Populate `agent-routing.yaml`** — pin / adjust per-agent tiers (it ships empty) | One file edit + re-session | Makes the matrix tunable per adopter; pins build engineers to `sonnet` explicitly so frontmatter drift can't silently raise the tier |

## Decision

1. **Axis A — A1 (new AgDR).** This document. Keeps AgDR-0050 immutable and gives the cost tension + levers a citable home. AgDR-0050 stands as the accepted runtime design; this AgDR records a consequence of its Axis-6 decision and the operator-facing mitigations.

2. **Axis B — B1 (document levers, keep Axis 6).** Axis 6's in-thread choice for in-flow work is correct for shared-context reasons; the answer is to make its cost consequence explicit and give operators levers, not to reverse it. The thin-orchestrator pattern (Axis C, C2) is the *opt-in* route for operators who want the matrix to apply to implementation — they get it by *choosing* to spawn, without the framework forcing the spawn on everyone.

3. **Axis C — all three levers, documented in operator-facing docs** (`docs/orchestrator-cost-model.md`, cross-referenced from `docs/getting-started.md`), in effort-to-win order: `opusplan` first (biggest win, no framework change), thin-orchestrator second (recovers the matrix for implementation via spawning), `agent-routing.yaml` third (per-adopter tuning surface).

4. **Frontmatter drift fix — confirm + guard.** `backend-engineer` and `frontend-engineer` agent files must read `model: sonnet` per the AgDR-0050 Axis-2 matrix. On the `dev` branch they are *already* `sonnet` (the `opus` drift the ticket describes existed only in an uncommitted working tree, never on `dev`), so this AgDR records the conformant state rather than editing the files — and points operators at `agent-routing.yaml` to *pin* these tiers so the drift can't silently recur. Review-agent routing is unchanged: Rex (`code-reviewer`) and Hakim (`security-reviewer`) stay `opus`; Nour (`ui-designer`) stays `sonnet`. No other agent's tier changes.

## Consequences

- **The cost model is documented, not surprising.** Operators reading `docs/orchestrator-cost-model.md` understand *why* the main agent dominates spend (in-flow work is in-thread by Axis-6 design) and *what to do about it* (the three levers).
- **Axis 6 is unchanged.** In-flow roles keep in-thread adoption; shared-context benefit preserved. This AgDR adds no new spawn behaviour.
- **The thin-orchestrator pattern is an opt-in mode**, not a default. Operators who want the matrix to apply to implementation spawn build agents via `/fan-out` / `Workflow` and keep the Opus loop thin (planner / coordinator). This composes directly with [AgDR-0068](AgDR-0068-governed-looping.md) — a governed loop with an Opus coordinator and spawned Sonnet build agents is exactly the thin-orchestrator shape, with the loop's halt-at-the-merge-gate guardrails.
- **Build-engineer tiers are confirmed matrix-conformant.** `backend-engineer` / `frontend-engineer` are already `sonnet` on `dev` — no agent file is edited by this AgDR. The drift guard (`block-agent-routing-drift.sh`, from AgDR-0050 Axis 4) catches any future re-drift on commit / push; operators can additionally pin the tiers via `agent-routing.yaml` so the matrix value is explicit.
- **No review-routing regression.** Rex / Hakim stay `opus`; Nour stays `sonnet`. No agent frontmatter changes in this PR.
- **`agent-routing.yaml` remains the per-adopter tuning surface.** The docs now point operators at it as a cost lever (pin tiers, route specific agents through cheaper models), closing the "ships empty, tuning surface unused" gap noted in the ticket.

## Artifacts

- This AgDR file: `docs/agdr/AgDR-0074-orchestrator-cost-model.md`
- Operator-facing cost-lever doc: `docs/orchestrator-cost-model.md`
- Agent frontmatter confirmed matrix-conformant (unchanged by this PR): `.claude/agents/backend-engineer.md`, `.claude/agents/frontend-engineer.md` (both `model: sonnet`)
- Related AgDRs:
  - [AgDR-0050 — agent runtime overhaul](AgDR-0050-agent-runtime-overhaul.md) — the per-agent matrix (Axis 2) + the Axis-6 in-thread/spawned split this AgDR documents the cost consequence of
  - [AgDR-0068 — governed looping](AgDR-0068-governed-looping.md) — the loop shape the thin-orchestrator pattern composes with
- Related rule:
  - [`.claude/rules/plan-mode.md`](../../.claude/rules/plan-mode.md) — `opusplan` prior art (Opus plans, Sonnet executes)
- Implementation ticket: [me2resh/apexyard#655](https://github.com/me2resh/apexyard/issues/655)

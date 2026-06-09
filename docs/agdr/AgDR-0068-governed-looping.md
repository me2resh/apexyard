# AgDR-0068 — Governed looping as an apexyard pattern

> In the context of the field shifting from prompting agents step-by-step to *designing loops that prompt agents*, facing the risk that ungoverned loops become billing surprises and confident-mistake machines, I decided to **adopt governed looping as a first-class apexyard pattern via a trigger-heuristic rule (`.claude/rules/loop-mode.md`) that recommends a closed loop when work fits and binds every loop to apexyard's existing gates as its eval**, rather than shipping a new `/loop` engine or leaving looping undocumented, to achieve the "design loops, not steps" workflow on a normal budget, accepting that this is self-discipline (no new mechanical hook) layered on the merge-gate backstop.

## Context

- Loops are the current frontier: stop being the thing typing prompts inside the loop; author the loop, and the model becomes the subroutine. The durable engineering lessons underneath the hype are narrow — **a loop is only as good as the skills it calls and its ability to verify itself, and it is only safe if it halts.**
- The expensive resource has shifted from the model (tokens to write code) to the *loop* (managing the agent, and stopping it). The dominant failure modes are the runaway loop (no halt → budget surprise) and the unverified loop (no eval → fast confident mistakes).
- ApexYard is unusually ready for looping: it already ships the two things loops depend on and most setups lack — a **skill library** (59 slash commands) and a real **eval layer** (Rex code review, design/architecture review, CI, the per-PR merge gate, QA). The gap was that looping wasn't *recommended* or *governed* — operators had to rediscover when/how to loop each time.
- Concrete in-session evidence: the v3 console redesign's 8 remaining views were built by a fleet loop (Workflow) — it produced 8 type-safe redesigns in parallel, but its verify stage ran only the build, not the test suite, leaving broken tests to fix afterward. That is the lesson made tangible: **the verify gate must include tests + Rex, not just build.**
- Lineage (for grounding, not novelty): ReAct (2022, reason→act→observe) → AutoGPT (2023, self-prompting, famously ran forever) → ralph (2025, fixed-context bash loop) → `/goal` (productized, validator-gated) → orchestration loops (loops supervising loops, scheduled, durable git-backed state). Single-agent ralph is old hat; multi-agent supervision with verification is the new layer.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| 1. **Trigger-heuristic rule + bind to existing gates** (chosen) | Mirrors the proven `parallel-work.md` / `plan-mode.md` shape; recommends looping proactively; reuses Rex/CI/merge-gate as the eval; zero new machinery; self-discipline + merge-gate backstop | Not mechanically enforced (no hook can see "should have looped"); relies on the agent following the rule |
| 2. Build a new apexyard `/loop` engine | Full control over loop mechanics | Re-implements a harness capability (`/loop`, `/schedule`, `Workflow` already exist); large surface; duplicates the gates |
| 3. Leave looping undocumented | No work | Operators rediscover when/how each time; no guardrails → runaway/unverified loops; the in-session FOUC/broken-test lesson recurs |

## Decision

Chosen: **Option 1 — a trigger-heuristic rule.** `.claude/rules/loop-mode.md` defines when to OFFER a closed loop (repetitive over a set · machine-verifiable · bounded), when not to, which primitive to use (harness `/loop` for single-agent iterate · `/fan-out` for N independent items · the `Workflow` tool for a verifying fleet), and the guardrails. The guardrails are the point: **halt at the per-PR CEO merge gate (never self-approve); verify = build + tests + Rex (not just build); a budget + iteration ceiling; no-progress detection; loops call named skills, not re-derived prompts.** The rule auto-loads via the `@.claude/rules/*.md` import.

## Consequences

- New file `.claude/rules/loop-mode.md`; `CLAUDE.md` rule count + list updated (11 → 12 rules) and a code-standards bullet added.
- Looping becomes a recommended, governed move — the agent proactively proposes it for fitting work and states the guardrails up front.
- The merge-gate hooks (`block-unreviewed-merge.sh` + `/approve-merge`) remain the mechanical backstop: a loop that tries to self-approve is already blocked, so the "halt at CEO gate" clause is enforced in practice even though the rule itself is advisory.
- Future hardening (deferred, candidate for a follow-up spike): mechanical budget enforcement, cron scheduling integration, and a possible `/loop`-wrapper skill that runs the SDLC as the loop body. Not needed for the recommend-and-guardrail goal.

## Artifacts

- `.claude/rules/loop-mode.md` (this AgDR's implementation)
- Feature: me2resh/apexyard#594
- Precedent rules: `.claude/rules/parallel-work.md`, `.claude/rules/plan-mode.md`
- Eval/gate rules cited: `.claude/rules/pr-workflow.md`, `.claude/rules/workflow-gates.md`

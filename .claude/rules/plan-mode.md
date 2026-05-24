# Plan Mode — When to Enter

Claude Code ships **plan mode** — a harness state where the agent thinks through a multi-step approach and presents it for user approval *before* executing any tool calls that mutate state. This rule is the **trigger heuristic** — it defines when an agent should proactively enter plan mode instead of jumping straight into tool calls.

A typical session jumps into execution on every request — even ones that decompose into several dependent steps with branching choices. The framework should make plan-mode-first the default for the cases where it pays off, not a pattern each user rediscovers by watching their agent thrash.

## When to ENTER plan mode (proactively)

Heuristic: enter plan mode when the user's request hits **any** of these:

- **Multi-step coordination (≥ 4 dependent steps)** — the steps share state, ordering matters, and a wrong early step costs visible rework
- **Unclear path** — there are 2+ plausible approaches and picking wrong means non-trivial backtracking
- **Hard-to-reverse action upcoming** — destructive ops (force push, branch delete, schema migration), externally-visible writes (PR/issue creation, message sends), shared-state changes
- **Validating a fan-out split** — before calling `/fan-out`, plan mode forces explicit articulation of the per-task scope so the parallel agents can't drift apart

Examples that should trigger plan mode:

- "Adopt repo X into the portfolio" (handover discovery — multi-step + branching on what the static read finds)
- "Debug why the marketplace add is silently failing" (unclear path + multiple hypotheses to triage)
- "Refactor module X from MVC to clean architecture" (multi-step + the file-move plan is the load-bearing decision)
- "File these 5 tickets and open PRs against each" (externally-visible writes, want to confirm the batch before any `gh issue create` fires)

## When NOT to enter plan mode

- **Single read or single edit** — `Read X`, `grep for Y`, `change line 42 from foo to bar`. Plan mode adds latency without removing risk.
- **Well-scoped patch with obvious next-action** — the user already named the file + the change, the change is reversible (one commit, one revert), and there's nothing to plan.
- **Conversation has already established the plan** — the user just spent five turns discussing the approach with you. Re-entering plan mode to re-present what was just agreed is ceremony.
- **Trivial work** — copy-paste edits, doc typos, label additions on a known issue. Same overhead-exceeds-gain calculus as `/fan-out` on three-line changes.

## Self-check before responding

Before answering a user request that involves tool calls, scan your planned response for:

```
[ ] Will this involve ≥ 4 dependent tool calls?
[ ] Are there ≥ 2 plausible paths and I haven't committed to one?
[ ] Am I about to do something hard-to-reverse (destructive, externally-visible, shared-state)?
[ ] Am I about to spawn parallel agents via /fan-out without an explicit per-task scope?
[ ] Did I write a multi-step plan in prose without entering plan mode?
```

If any box is checked and you didn't enter plan mode, you missed an opportunity. The last item — *"wrote a multi-step plan in prose"* — is the most common failure mode and the easiest to catch retroactively.

## Prior art

Anthropic's `opusplan` model alias is a related prior-art pattern: Opus runs during plan mode (deeper reasoning while the cost matters), Sonnet runs during execution (cheaper while the choices are mechanical). See [Claude Code model configuration](https://code.claude.com/docs/en/model-config) for the alias and tier-routing semantics. The `opusplan` shape implies plan mode is meant as a *deliberate, more-expensive thinking phase*, not a default-on ceremony — which lines up with the "when NOT to enter" list above.

## Backstop

This rule is **primarily self-discipline**. Mechanical enforcement isn't viable — plan mode is harness-owned (the harness owns `EnterPlanMode` / `ExitPlanMode`), so no shell hook can see "the agent should have entered plan mode but didn't" in assistant prose. Pair this rule with feedback memory: if the CEO has previously asked "why didn't you plan this first?", surface plan mode more aggressively next time.

The cost of entering plan mode and being told "skip the plan, just do it" is a quick `ExitPlanMode`. The cost of jumping into tool calls on a multi-step task with an unclear path is the visible rework the user has to watch you do.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

# Orchestrator cost model — why the main agent dominates spend, and the three levers

If you run ApexYard and notice the **main agent dominating your token bill**, this is expected behaviour with a structural cause — not a misconfiguration. This doc explains *why*, then gives you three levers to manage it, ordered by effort-to-win ratio.

Full design rationale: [AgDR-0074](agdr/AgDR-0074-orchestrator-cost-model.md). Underlying runtime design: [AgDR-0050](agdr/AgDR-0050-agent-runtime-overhaul.md).

---

## Why the main agent dominates spend

[AgDR-0050](agdr/AgDR-0050-agent-runtime-overhaul.md) ships a **per-agent model matrix** — a default tier per sub-agent:

| Tier | Agents (examples) | Why |
|------|-------------------|-----|
| `opus` | Tech Lead, SRE, Pen Tester, **Security Auditor (Hakim)**, **Code Reviewer (Rex)** | Depth-bound reasoning |
| `sonnet` | **Backend / Frontend Engineer**, Platform / Data Engineer, Product Manager, **UI Designer (Nour)**, UX Designer | Implementation + tool-use default |
| `haiku` | QA Engineer, Data Analyst | Checklist-shaped, repeatable work |

The matrix is real and correct — **but it only applies to *spawned* sub-agents.** A sub-agent's model comes from its frontmatter (`model:` in `.claude/agents/<name>.md`), which the harness reads when it *spawns* the agent.

Per [AgDR-0050 § Axis 6](agdr/AgDR-0050-agent-runtime-overhaul.md), role activations split into two classes:

- **Isolated-work-class** roles (QA, Pen Tester, Data Analyst, Heads-of-X, **Security Auditor, Code Reviewer**, Tech Lead reviews) → auto-triggers **spawn a sub-agent**. The matrix applies. ✅
- **In-flow-class** roles (**Backend / Frontend Engineer**, Platform / Data Engineer, Product Manager, UI / UX Designer) → auto-triggers keep **in-thread persona adoption**, because spawning out-of-thread loses the shared "what just happened" context that ship-the-code flow needs.

In-thread adoption **does not spawn anything** — it injects the role file into the main thread, which keeps running on whatever model is driving the conversation (typically your primary tier, usually **Opus**). So:

- **Reviews route correctly** — Rex + Hakim are spawned, so their `opus` frontmatter applies.
- **Implementation does not** — Backend / Frontend Engineer work is adopted in-thread, so the `sonnet` default in their frontmatter is never consulted. Implementation — the highest-volume work in any SDLC — runs at your primary tier.

That's the tension in one line: **the matrix optimises the spawned minority (reviews); the in-thread majority (implementation) runs on your primary tier.** The matrix works — it just can't reach the work that costs the most, by Axis-6 design (which is the right call for shared context).

---

## The three levers

You don't reverse Axis 6 to fix this — in-flow work genuinely benefits from shared context. Instead you pick one (or more) of these levers. They are ordered by effort-to-win ratio: do C1 first.

### Lever 1 — `opusplan` (biggest single win, no framework change)

The harness ships an `opusplan` model alias: **Opus runs during plan mode** (deeper reasoning while the choices matter), **Sonnet runs during execution** (cheaper while the choices are mechanical). The high-volume *execution* phase — which is where the in-thread implementation work lives — drops to Sonnet, while planning keeps Opus depth.

This is the single biggest win and requires **zero framework change** — it's an operator model-config choice. See [Claude Code model configuration](https://code.claude.com/docs/en/model-config) for the alias and tier-routing semantics, and [`.claude/rules/plan-mode.md`](../.claude/rules/plan-mode.md) § "Prior art" for how it lines up with ApexYard's plan-mode discipline.

```text
opusplan:  Opus (plan mode) ──▶ Sonnet (execution)
```

If you do nothing else, do this.

### Lever 2 — the thin-orchestrator pattern (recover the matrix for implementation)

Keep the **Opus main loop as a thin planner / coordinator** — it plans, decomposes, sequences, and gates — and **delegate well-scoped implementation to *spawned* `sonnet` build agents** via [`/fan-out`](../.claude/skills/fan-out/SKILL.md) (N independent items, one pass each) or the `Workflow` tool (a verifying fleet). Because the build agents are *spawned*, the model matrix applies — implementation runs on `sonnet`, the coordinator stays Opus.

This is the opt-in route for operators who want the matrix to apply to implementation *without* giving up shared-context for the planning loop. You get the cheap tier for the bulk by *choosing* to spawn, instead of the framework forcing a spawn on everyone.

```text
Opus loop (thin: plan · decompose · sequence · gate)
   │
   ├─▶ /fan-out  ──▶ sonnet backend-engineer   (ticket A)
   ├─▶ /fan-out  ──▶ sonnet frontend-engineer  (ticket B)
   └─▶ spawn     ──▶ opus  code-reviewer (Rex) ──▶ HALT at CEO merge gate
```

**Guardrails (from [AgDR-0068 — governed looping](agdr/AgDR-0068-governed-looping.md), and [`.claude/rules/loop-mode.md`](../.claude/rules/loop-mode.md)):** a thin-orchestrator loop **MUST halt at the per-PR CEO merge gate** — it never self-approves. Its verify stage runs **build + tests + Rex**, not just build. And it has a **budget / iteration ceiling**. The thin-orchestrator pattern *is* a governed loop with an Opus coordinator and spawned Sonnet workers — the loop-mode guardrails apply unchanged.

#### Opt-in "thin-orchestrator mode"

Treat this as an explicit mode you opt into for a session, not a silent default. When you want it, say so up front — e.g. *"run thin-orchestrator: you stay Opus as planner, fan implementation out to Sonnet build agents, halt at every merge gate."* The agent then:

1. Plans + decomposes in the Opus loop (ideally under `opusplan`, so even planning's execution sub-steps are Sonnet).
2. Spawns `sonnet` build agents per well-scoped ticket (`/fan-out` for independent items; `Workflow` for a verifying fleet).
3. Runs the real `opus` reviewers (Rex / Hakim) as separate spawns — build agents **cannot** self-review (see [`.claude/rules/pr-workflow.md`](../.claude/rules/pr-workflow.md) § "Build agents cannot self-review").
4. **Stops at the per-PR CEO merge gate** and hands back for the explicit approval.

This composes with `opusplan` (Lever 1): use both — `opusplan` cheapens the coordinator's own execution sub-steps, thin-orchestrator cheapens the delegated implementation.

### Lever 3 — populate `agent-routing.yaml` (per-adopter tuning)

`agent-routing.yaml` ships **empty** (`agents: {}`), so the per-agent tuning surface is unused by default. It's the one-file place to pin or adjust per-agent tiers — including **pinning the build engineers to `sonnet` explicitly** so frontmatter drift can't silently raise the tier, or routing specific agents through cheaper / local models.

```yaml
# agent-routing.yaml
version: 1
agents:
  backend-engineer:
    model: sonnet          # framework default; explicit pin guards against drift
  frontend-engineer:
    model: sonnet          # framework default; explicit pin
  data-analyst:
    model: haiku           # framework default; or bump to sonnet for richer SQL
```

At SessionStart the sync hook (`apply-agent-routing.sh`) rewrites the affected agent-file frontmatter in place; drift guards keep adopter routing choices out of the public fork. See [`agent-routing.yaml.example`](../agent-routing.yaml.example) for the full schema (model / endpoint / env / timeout) and [`docs/local-model-setup.md`](local-model-setup.md) for routing specific agents through a local Ollama endpoint as a further cost / privacy lever.

> **Note:** `agent-routing.yaml` tunes the model of *spawned* sub-agents. It does **not** change the tier of *in-thread* in-flow work — that's governed by your primary tier and Lever 1 (`opusplan`). Use Lever 3 to make the matrix tunable; use Levers 1 + 2 to reach the in-thread majority.

---

## Quick reference

| Symptom | Lever | Effort | Reaches |
|---------|-------|--------|---------|
| Main agent dominates spend | **1 — `opusplan`** | Operator config, zero framework change | Execution phase of the in-thread loop → Sonnet |
| Want the matrix to apply to implementation | **2 — thin-orchestrator** | Operator workflow change | Delegated implementation → spawned Sonnet build agents |
| Want per-adopter tier control | **3 — `agent-routing.yaml`** | One file edit + re-session | Spawned sub-agents (pin / route / local) |

Start with Lever 1. Add Lever 2 for implementation-heavy sessions. Use Lever 3 to make the whole matrix tunable for your fork.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

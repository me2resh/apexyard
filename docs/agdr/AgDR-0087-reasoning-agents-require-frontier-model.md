# AgDR-0087 — Reasoning-layer agents require a frontier model; local/open LLMs are a harness concern, not a framework change

> In the context of spike #660 asking whether the full ApexYard loop can run on open-weights/local LLMs with no proprietary-API dependency, facing a split between a governance layer that is already model-agnostic and a reasoning layer that is not, I decided **that the mechanical/gate layer stays model-agnostic and self-hostable via the harness adapters while the reasoning-layer agents (Rex/Hakim/Tariq/Naqid + the orchestrator) require a frontier model — and that local/open-LLM support is a harness+model choice, not a framework change**, to achieve run-anywhere mechanical governance without lowering the merge-gate review floor, accepting that a fully self-hosted zero-Claude configuration cannot meet the framework's review-depth bar today.

## Context

Spike #660 hypothesised (building on #348, cited as having "validated local routing for 3 low-stakes agents") that the whole loop — code review (Rex), build engineers, design/security review, core skills — could run on strong open-weights models via `agent-routing.yaml` → Ollama/LiteLLM at a usable governance bar, giving adopters a fully self-hostable, no-Claude configuration.

The spike found the question splits into two layers, only one viable:

- **Mechanical/gate layer** — the bash hooks enforcing merge gates, red-CI blocking, design review, ticket-first, secrets/leak-protection — is already harness-agnostic and proven portable: the pi.dev (#815) and opencode (#821) adapters shell out to the unmodified hooks with no dependency on which model drives the session. No new framework work needed.
- **Reasoning layer** — Rex, Hakim, Tariq, Naqid, and the orchestrating main thread — is **not** viable at a usable governance bar on any open-weights model tested or evidenced. AgDR-0050's 24-agent model matrix already pins these depth-bound reviewer roles to `opus` (its stated capability floor), independent of this spike.

New live evidence the spike added: a real merged security-relevant PR (#793, a fail-closed CI-gate fix) was fed to the strongest locally-available coding model (`qwen3-coder`, ~20B) through Rex's actual review checklist. The review completed (424.5s wall-clock, ~111s pure compute — roughly **300x** a synchronous Claude-driven Rex pass) but **never engaged the one question the prompt told it to check** — whether the gate fails closed or open on an unresolvable status, the load-bearing security decision in that PR — raising five generic SUGGESTION-level nitpicks instead. A fluent-but-incomplete review that looks thorough while missing the actual risk is a worse failure mode for a merge-gate reviewer than a visible timeout. A parallel `mistral` call timed out under contention, confirming the single-endpoint constraint. The spike also corrected the ticket's premise: #348 was closed unrun; #195 (the spike that did measure) landed a narrow partial-GO limited to prose-synthesis, explicitly rejecting local routing for anything that must count, classify precisely, or reason about a diff.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| (a) **Full local** — route all agents, including Rex/Hakim/Tariq/Naqid + orchestrator, to open-weights/local models | Zero proprietary-API dependency; fully self-hostable | Live evidence shows the reasoning layer misses the load-bearing risk at ~300x latency; a fluent-but-incomplete merge-gate review is worse than a timeout; contradicts AgDR-0050's `opus` pin reached independently |
| (b) **Hybrid** — mechanical/gate layer model-agnostic (local-OK), reasoning layer pinned to a frontier model | Governance runs anywhere; keeps the review-depth floor where the evidence and AgDR-0050 both put it; low-stakes sub-tasks (triage, SQL sketches, AC checklists, prose synthesis) can still route local per #195 | Not "zero-Claude" — the reasoning floor still needs a frontier model |
| (c) **No framework change** — treat local-LLM support as a harness+model choice (BYOK harness + a capable model), shipped via the existing adapters, not a framework feature | Nothing to build; self-hosted mechanical gates already work via #815/#821; matches how the framework already ships the *pattern*, not a recommendation | Adopters wanting local reasoning get the same frontier-floor answer; no new self-hostable reasoning tier is delivered |

## Decision

Chosen: **(b)/(c) — the reasoning layer stays frontier; local/open-LLM support is a harness concern, not a framework change.** The mechanical governance layer is already model-agnostic and self-hostable through the harness adapters (#815/#821); the depth-bound reviewer roles keep a frontier-model floor.

"Self-hosted, zero-Claude, full governance bar" — the ticket's actual ask — is not viable today at any open-weights tier this spike could test or find evidence for, and the framework's own designers reached the same conclusion independently by pinning Rex/Hakim/Tariq/Naqid/SRE/Pen-Tester to `opus` in AgDR-0050. Re-opening the full-loop question now would be asking, for the third time, something already answered twice (#348 closed unrun, #195 partial-GO for prose only).

## Consequences

- Mechanical governance (merge gates, red-CI, ticket-first, secrets/leak-protection) runs anywhere via the harness adapters — self-hosted mechanical enforcement needs no proprietary API.
- Review quality has a **frontier-model floor**: the reasoning-layer agents are not routed to open-weights models; low-stakes sub-tasks (ticket triage, SQL sketches, AC checklists, prose synthesis) may still route local per `agent-routing.yaml` and #195's narrow recommendation.
- This is a "not yet", not a permanent no. Revisit only via the **narrower re-test the memo proposes**: does a specific coding-tuned open model (e.g. `qwen2.5-coder:14b`, matching typical adopter hardware) clear Rex's real review checklist across 10–15 real merged PRs with known outcomes — turning "this happened once" into a measured rate. That ~2–3 day measurement, not framework rework, is the missing evidence.

## Artifacts

- Spike disposition memo: [`docs/spike-memos/GH-660-local-open-llms.md`](../spike-memos/GH-660-local-open-llms.md)
- Spike ticket: me2resh/apexyard#660 (DISCARD); PR #823
- Model matrix pinning the depth-bound reviewer roles to `opus`: [AgDR-0050](AgDR-0050-agent-runtime-overhaul.md)
- Prior local-routing history: me2resh/apexyard#348 (closed unrun), #195 (`docs/spikes/local-model-routing.md`, live-measured partial-GO)
- Multi-harness adapters delivering self-hosted mechanical gates: #804 → #815 (pi.dev), opencode gate adapter spike → #821

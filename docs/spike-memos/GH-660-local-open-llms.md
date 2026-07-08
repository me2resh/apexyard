# Spike memo: Run the full yard on open / local LLMs (Ollama / open-weights) — no proprietary-API dependency

> **Disposition: DISCARD** — hypothesis rejected at the ticket's stated bar; not pursuing further.

- **Spike ticket**: me2resh/apexyard#660
- **Author**: me2resh
- **Closed**: 2026-07-08

## Hypothesis (from the spike ticket)

Building on #348 (cited as having "validated local routing for 3 low-stakes agents"), the hypothesis was that the full apexyard loop — code review (Rex), build engineers, design/security review, the core skills — could run on strong open-weights/local models via `agent-routing.yaml` → Ollama/LiteLLM at a usable governance bar, giving adopters a fully self-hostable configuration with no Claude/proprietary-API dependency.

## Findings

The question splits into two layers, and only one of them is viable. The **mechanical/gate layer** — the bash hooks that enforce merge gates, red-CI blocking, design review, ticket-first, secrets/leak-protection — is already harness-agnostic and proven portable: two independent spikes (pi.dev → #815, opencode → #821) showed a thin per-harness adapter shelling out to the unmodified bash hooks, with no dependency on which model drives the session. This part needs no new framework work.

The **reasoning layer** — Rex, Hakim, Tariq, Naqid, and the orchestrating main thread itself — is not viable at a usable governance bar on any open-weights model tested or evidenced. The framework's own model matrix (AgDR-0050) already pins these roles to `opus`, its own stated capability floor, independent of this spike. This spike added new live evidence: a real merged security-relevant PR (#793, a fail-closed CI-gate fix) was fed to the strongest locally-available coding model (`qwen3-coder`, ~20B) through Rex's actual review checklist. The review completed (424.5s wall-clock, ~111s of that pure compute — roughly 300x a synchronous Claude-driven Rex pass) but never engaged with the one question the prompt explicitly told it to check: whether the gate fails closed or open on an unresolvable status, the load-bearing security decision in that PR. It raised five generic, SUGGESTION-level defensive-programming nitpicks instead. A fluent-but-incomplete review — one that looks thorough while missing the actual risk — is a worse failure mode for a merge-gate reviewer than a visible timeout would have been. A parallel call to a smaller model (`mistral`) timed out under resource contention, confirming the single-endpoint constraint the framework's own local-model docs already document.

The ticket's premise also overstated prior evidence: #348 (cited as having "validated local routing") was actually closed unrun — the design pivoted to "framework ships the pattern, not a recommendation" without ever measuring anything. #195, the spike that did run live measurements, landed a narrow partial-GO limited to prose-synthesis tasks (inbox summaries via a regex-extracts/LLM-narrates hybrid) — explicitly rejecting local routing for anything that needs to count, classify precisely, or reason about a diff.

## Why we're not pursuing

"Self-hosted, zero-Claude, full governance bar" — the ticket's actual ask — is not viable today at any open-weights tier this spike could test or find evidence for, and the framework's own designers already reached the same conclusion independently by pinning the depth-bound reviewer roles to `opus`. What *is* already shipped and requires no further work: self-hosted mechanical gates via the harness adapters (#815/#821), plus local/open routing for genuinely low-stakes sub-tasks (ticket triage, SQL sketches, AC checklists, prose synthesis) per `agent-routing.yaml` and #195's narrow recommendation. Re-opening the full-loop question would be asking, for the third time, something already answered twice.

## What would change the answer

A future open-weights release that closes the review-depth gap at a size that runs comfortably on typical adopter hardware — worth periodic re-testing, not a permanent no. Restructuring the review gate to be async-tolerant (accepting a multi-minute local-model review as normal instead of expecting Rex-in-seconds) would remove the latency objection independently of the quality one, but that's an SDLC-shape change, out of this spike's scope. Most concretely: a narrower, sharper follow-up spike — does a specific coding-tuned open model (e.g. `qwen2.5-coder:14b`, matching more typical adopter hardware than the 20B model this spike hit a wall with) clear Rex's real review checklist across 10-15 real merged PRs with known outcomes — would turn "this happened once" into an actual measured rate. That measurement, not framework rework, is the one piece of real evidence still missing; it's roughly a 2-3 day effort, matching #348's own original unfulfilled budget.

## Artefacts

- Decision record: [AgDR-0087](../agdr/AgDR-0087-reasoning-agents-require-frontier-model.md) — the "reasoning layer needs a frontier model; local LLMs are a harness concern" decision this memo records
- Original spike ticket: me2resh/apexyard#660
- Spike branch: `spike/GH-660-local-open-llms` (delete after merge of this memo)
- Full findings: `docs/spike-reports/GH-660-local-open-llms.md` on the spike branch
- Related: me2resh/apexyard#348 (closed unrun, local-routing feasibility), `docs/spikes/local-model-routing.md` (spike #195, live-measured partial-GO), [AgDR-0050](../agdr/AgDR-0050-agent-runtime-overhaul.md) (the 24-agent model matrix pinning Rex/Hakim/Tariq/Naqid to `opus`), `docs/local-model-setup.md`, #804 → #815 (pi.dev gate adapter), opencode gate adapter spike → #821

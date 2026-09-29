# Spike memo: Evaluate optional TypeSafe/Jev routing for framework workflows

> **Disposition: DISCARD** — hypothesis rejected; not pursuing further.

- **Spike ticket**: me2resh/apexyard#1341
- **Spike PR**: me2resh/apexyard#1349 (closed without merge; its report is summarised here)
- **Author**: me2resh
- **Closed**: 2026-09-29

## Hypothesis (from the spike ticket)

Jev, a typed-classification model, could improve advisory routing for framework skills, roles and ceremony when users describe work without the exact phrases in the current maps. It must not change an enforcement decision or remove the deterministic fallback.

## Findings

The spike ran a shadow evaluation on a 15-case labelled corpus on the `dev` line (v5.6.3) on 2026-09-18. Jev had no provider failures. Its mean latency was about 0.6 to 0.7 seconds. Its accuracy was 73% for skills, 67% to 80% for roles, and 33% to 47% for ceremony. The answers were not fully stable between runs: one case changed its role answer. Jev caught paraphrases that the literal phrase maps miss. It also suggested skills for role-only prompts, and it often chose a ceremony that did not match the label.

## Why we're not pursuing

Jev does not beat the deterministic phrase maps on false positives and false negatives, and its ceremony classification is unreliable. A model with these results must not take part in enforcement or approval decisions. The shipped hooks stay deterministic, with human-readable advisory banners.

## What would change the answer

- Larger corpora, labelled independently of the model under test.
- An abstention policy, so the model can decline to route when it is unsure.
- A cost and latency comparison against a small Claude model that shows a clear benefit.
- An explicit failure-path test for any future integration.

Until that evidence exists, the dependent tickets #1342 and #1343 stay blocked. The AgDR-completeness pass in the report is a possible research direction, but its structural proxy is not a quality oracle.

## Artefacts

- Original spike ticket: me2resh/apexyard#1341
- Spike PR and full report: me2resh/apexyard#1349 (`docs/spikes/jev-routing-evaluation.md` on its branch)
- Evaluator scripts: `bin/evaluate-jev-routing.py` and `bin/evaluate-jev-routing-corrected.py` on the spike branch; not merged

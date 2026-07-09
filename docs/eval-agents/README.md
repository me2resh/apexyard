# `/eval-agents` corpus — labeled ground truth for the review agents

This directory holds the labeled corpus that `/eval-agents` (`.claude/skills/eval-agents/SKILL.md`) scores Rex / Hakim / Tariq against. Methodology and the rationale for this exact schema: [AgDR-0089](../agdr/AgDR-0089-eval-agents-methodology.md). Short version: a text-only LLM-judge rubric was tested in spike #825 and found to be at-chance on the question that matters (was an approval justified) — so this corpus freezes **ground-truth defects**, established once and offline, and `/eval-agents` scores each fresh agent run by set-overlap against that frozen answer key. It never asks a judge to rate review prose.

## Layout

```
docs/eval-agents/
  README.md              this file
  SCHEMA.md              the corpus entry format, field by field
  corpus/
    rex.json             starter corpus for the code-reviewer agent (Rex)
    hakim.json            starter corpus for the security-reviewer agent (Hakim)
    tariq.json            NOT SEEDED — see below
  reports/
    <agent>-<date>.md     dated run reports, written by /eval-agents
```

## What's seeded, and what isn't

- **Rex (`corpus/rex.json`)** — 6 entries mined from this repo's own review history: two confirmed MISSes (wrong approvals — both caught by Hakim's independent review of the identical commit; both entries carry `oracle.source: independent_review`, not `confirmed_fix` — the fix that landed afterward corroborates the defect but isn't the oracle basis), two GOOD_CATCH (correctly required changes), and two GOOD_CLEAN (correctly approved a genuinely clean diff).
- **Hakim (`corpus/hakim.json`)** — 4 entries: three GOOD_CATCH, one GOOD_CLEAN. **No confirmed Hakim MISS is seeded yet** — the spike's sample didn't surface a clean Hakim-authored wrong approval. This is a real, documented gap. Approve-precision on the Hakim starter run will trivially read 1.0 until a genuine miss is harvested and added; treat that number as "no counter-evidence yet," not "Hakim is perfect."
- **Two entries are same-diff cross-agent pairs** (`rex-792-2ce6708` / `hakim-792-2ce6708`, and `rex-767-a99f1009` / `hakim-767-a99f1009`) — the identical commit, reviewed by both agents the same day, with different outcomes (Rex approved, Hakim caught a real defect). These are the cleanest possible corpus entries: the diff is held constant, only the reviewing agent varies.
- **Tariq — no starter corpus.** No Tariq-reviewed PRs were in the spike's sample. `/eval-agents tariq` requires an operator-supplied `--corpus <path>` until one exists.
- **Naqid — out of scope for v1.** Naqid challenges premises, not diffs; it has no defect-set structure to score against. See AgDR-0089 § Decision point 7.

## How the starter corpus was built

Every entry traces back to a real, merged `me2resh/apexyard` PR. Ground truth was established one of three ways (recorded per-entry in the `oracle` field):

- `independent_review` — a *different* reviewer (e.g. Hakim) caught the defect while reviewing the identical commit that the agent-under-test (e.g. Rex) approved.
- `confirmed_fix` — a defect a reviewer flagged was actually fixed in a subsequent commit, proving it was real.
- `no_contradiction` — a clean approval that no later review or fix ever contradicted.

This is the same mining method spike #825 used for its own labeled set (`docs/spike-825/judge_calibration.py`), reshaped from rubric-scores into defect-sets.

## Non-determinism caveat

Every score `/eval-agents` reports is downstream of two LLM steps, not a fixed measurement: the candidate spawn re-reviewing the diff, and the defect-overlap match against the frozen `ground_truth_defects` key. The key itself is frozen — that's the whole point of AgDR-0089 — but *comparing a fresh run's findings to that key* is a semantic judgment call, not a byte-for-byte diff, and can land differently on a borderline entry from one run to the next. A score delta between two runs of the same corpus against the same agent is **not automatically a real regression**; it can be run-to-run noise in the matching step. Read a delta by checking which specific entries flipped and re-reading the agent's actual output for those entries — never by trend-lining the raw percentage alone.

## Growing the corpus

Corpus growth is deliberately manual and human-adjudicated in v1 — `/eval-agents` validates an entry's *schema*, not its *truth*. To add an entry:

1. Find a real re-review disagreement (round N approved, round N+1 or a parallel reviewer said CHANGES REQUESTED / BLOCKING on the same commit) or an escaped bug (a merged PR followed by a `fix(#...)` touching the same files).
2. Write the `ground_truth_defects` from what the *later* signal actually found — not from what seems plausible.
3. Record the `oracle` honestly. If you can't point to independent-review or confirmed-fix evidence, don't invent it — leave the entry out rather than fabricate ground truth. A fabricated defect produces a confidently wrong score, which is worse than a smaller corpus.
4. Validate with `/eval-agents <agent> --check-only`.

See [`SCHEMA.md`](SCHEMA.md) for the field-by-field format.

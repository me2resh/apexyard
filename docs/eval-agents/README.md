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

- **Rex (`corpus/rex.json`)** — 9 entries mined from this repo's own review history: two confirmed MISSes (wrong approvals — both caught by Hakim's independent review of the identical commit; both entries carry `oracle.source: independent_review`, not `confirmed_fix` — the fix that landed afterward corroborates the defect but isn't the oracle basis), two GOOD_CATCH (correctly required changes), and five GOOD_CLEAN (correctly approved a genuinely clean diff).
- **Hakim (`corpus/hakim.json`)** — 4 entries: three GOOD_CATCH, one GOOD_CLEAN. **No confirmed Hakim MISS is seeded yet** — the spike's sample didn't surface a clean Hakim-authored wrong approval. This is a real, documented gap. Approve-precision on the Hakim starter run will trivially read 1.0 until a genuine miss is harvested and added; treat that number as "no counter-evidence yet," not "Hakim is perfect."
- **Three entries are same-diff cross-agent pairs** (`rex-792-2ce6708` / `hakim-792-2ce6708`, `rex-767-a99f1009` / `hakim-767-a99f1009`, and `rex-773-ca3a9400` / `hakim-773-ca3a9400`) — the identical commit, reviewed by both agents the same day. The first two have different outcomes (Rex approved, Hakim caught a real defect); the third is a matched clean pair (both agents correctly approved). These are the cleanest possible corpus entries: the diff is held constant, only the reviewing agent varies.
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

## Candidate corpus entries (needs human adjudication before adding)

Found while working me2resh/apexyard#861 (the first `/eval-agents rex` run's follow-ups). These are **proposed only** — none are promoted into `corpus/*.json` yet, per rule 7 (no fabricated ground truth; an entry only ships with real, checkable evidence). Two sources were mined:

### A. Unpromoted rows from spike #825's own labeled set

`docs/spike-825/judge_calibration.py`'s `DATA` table has **19** hand-labeled review-units; the starter corpus only promoted **10** of them into JSON (6 Rex + 4 Hakim). Three more Rex GOOD_CLEAN rows were promoted directly into `rex.json` during #861 (`rex-773-ca3a9400`, `rex-778-64c3ff5`, `rex-787-512d253` — all independently re-verified via the GitHub reviews API before adding, not taken on the spike's label alone). The rows below are the **remaining unpromoted** ones — real, human-labeled by the spike, PR numbers confirmed to exist and be merged, but not yet re-verified against the actual review text/commit SHA the way the promoted ones were:

| Spike row | PR | Commit (short, per spike) | Outcome | Note (per spike) |
|---|---|---|---|---|
| R11 | #688 | `0a54561` | GOOD_CLEAN | "cd-target re-root; adversarial verify; correct" |
| R12 | #689 | `c00e644` | GOOD_CLEAN | "merge-gate re-root; flagged latent follow-up; correct" |
| R13 | #634 | `10969b1` | GOOD_CLEAN | "push-ref regex; full edge-case table; correct" |
| R14 | #789 | `bc429fb` | GOOD_CLEAN | "agent-role rule; diff-scope verified; correct" |
| R16 | #747 | (unresolved — spike tagged it `chg?`) | GOOD_CLEAN | "active-ticket re-root; proved regression by revert; correct" |

All five PR numbers are confirmed real and merged (`gh pr view <N> --repo me2resh/apexyard`). **R16 needs the most care before promotion**: PR #747 has 3 separate `atlas-apex` review rounds recorded (not 1), so the specific commit SHA and verdict the spike's `chg?` tag refers to needs to be resolved from the PR's actual review timeline before writing `ground_truth_defects`/`recorded_verdict` — don't guess which round matches "proved regression by revert."

To promote any of these: pull the PR's review history (`gh api repos/me2resh/apexyard/pulls/<N>/reviews`), confirm the actual reviewed commit SHA and verdict text (mirror the process used for `rex-773`/`rex-778`/`rex-787` above — re-verify from the primary source, don't trust the spike's shorthand note alone), then follow "Growing the corpus" above.

### B. Real framework bugs that do NOT cleanly fit the corpus shape (documented so this ground isn't re-covered)

Several real, merged-and-fixed framework bugs were investigated as candidates and rejected — not because they aren't real defects, but because the corpus needs a **specific commit Rex/Hakim actually reviewed and gave a verdict on**, and these were discovered operationally (a user or an agent hit the bug in practice) rather than through a review-round disagreement:

- **#47** (`gh api .../merge` bypass) — the introducing commit (`c93cc52`, PR #10, April 2026) predates any recorded formal review state on this repo (bootstrap era — the PR that added the review-enforcement mechanism itself). No `recorded_verdict` can be honestly reconstructed. Its *class* of bug (a forge-specific merge-shape gate gap) is already represented via `rex-767`/`hakim-767` (the GitLab-side reopening of the same bypass class).
- **#568** (PR-extractor grabs a stray number from a `2>&1` redirect) and **#643** (same class, recurring in `block-merge-on-red-ci.sh` because the #568 fix didn't propagate to every call site) — both filed by external reporters/operators (`rafik-wahid-cubeish`, `khaledmedra`) hitting the bug in real usage, not surfaced by a review round.
- **#559** / **#746** / **#230** / **#229** / **#485** / **#728** (review-marker path/keying mismatches — split-portfolio resolution, repo-qualification, forged-marker guardrail) — all self-reported by `atlas-apex` ("observed in practice") after hitting the failure operationally, not from a Rex/Hakim review catching it in a diff.

If a future search wants to turn any of these into a corpus entry, the missing piece is the same in every case: find the PR that *introduced* the bug and confirm it received a real Rex/Hakim review verdict (not just that the bug shipped) — otherwise there's no `recorded_verdict` to record honestly.

### C. The standing Hakim-MISS gap

Per "What's seeded" above, `hakim.json` has zero confirmed MISS entries. Spike #825's 19-row sample didn't surface one either (the two Hakim rows outside GOOD_CLEAN are both `hakim-792` GOOD_CATCH). This is the single highest-value gap to close — closing it requires a security-relevant PR where Hakim approved and a subsequent finding (a later security review, an incident, or a confirmed fix to a Hakim-approved commit) proved a real defect was missed. None was found during #861; flagged here so the next corpus-growth pass starts here instead of re-discovering the gap.

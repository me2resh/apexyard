# Spike #825 — Does an LLM-judge's review score correlate with real ship/reject outcomes?

**Groundwork for feature #824 (`/eval-agents`).** Throwaway, hypothesis-driven, time-boxed.

## The question

If we score the framework's review agents (Rex / Hakim / Tariq) with an LLM-judge
against a rubric, do those judge scores **correlate with the real ship/reject
outcomes that already happened in this repo's history**? A high judge score should
predict "this review was good / the PR shipped clean"; a low score should predict
"this review missed something / got reworked."

## Verdict

**PROVEN-WITH-CAVEATS — and the caveat is the finding, not a footnote.**

A rubric applied to review *text* rank-orders reviews roughly in line with outcome
in aggregate (Goodman-Kruskal **gamma = 0.83**, n = 19 review units). But that
aggregate number is a mirage produced by the easy end of the distribution. On the
one job `/eval-agents` actually exists to do — **decide whether an APPROVAL was
justified** — the rubric is **at chance**. The mean judge score of a *correct*
approval (14.00/16) is statistically indistinguishable from a *wrong* approval
(13.67/16), and the single most fluent wrong-approval in the corpus scored 15/16,
beating 7 of the 10 genuinely-correct approvals.

**A surface LLM-judge cannot tell a thorough-and-right review from a
thorough-looking-but-wrong one.** That is precisely the failure mode a weak review
model produces, and precisely the thing `/eval-agents` is being built to catch.

## Method

Read-only over this repo's own merged-PR history (`me2resh/apexyard`). No agents
spawned (sub-agents can't nest); I acted as the single judge.

1. **Ground truth from history.** Pulled review + comment bodies for 15 merged PRs.
   This repo posts full agent reviews (Rex = code, Hakim = security) as PR review
   bodies, with explicit `Verdict: APPROVED / CHANGES REQUESTED / BLOCKING` lines and
   re-review rounds — an unusually clean ground-truth source, because a **later or
   parallel review of the same commit tells you whether an earlier review was right
   or wrong.**

2. **Labeled set = 19 "review units"** (one reviewer's assessment of one commit),
   each with a ground-truth outcome:
   - `GOOD_CATCH` (6) — verdict correct AND surfaced a real blocking/substantive
     defect that was then fixed.
   - `GOOD_CLEAN` (10) — verdict correct on genuinely clean code (no blocking
     defect existed; no later fix contradicted the approval).
   - `MISS` (3) — APPROVED a commit that a next-round / parallel review proved still
     carried a **blocking** defect at that same commit. The approval was *wrong*.

3. **Judge harness** (`judge_calibration.py`, alongside this file). A 4-dimension
   rubric, 0-4 each (0-16 total), scored from the **review text only** — i.e. what
   an LLM-judge that *reads the review but does not independently re-review the
   diff* would produce:
   - **Catch** — issues surfaced, with specific reasoning
   - **Engagement** — load-bearing (fail-open / injection / regression), independent
     verification present, not generic checklist-ticking
   - **Calibration** — severity labels sane, verdict matches the stated evidence
   - **False-positive discipline** — flagged issues are real, not noise

   The MISS reviews were deliberately scored **high** where they read as fluent and
   verification-heavy, because that is exactly what a blind surface judge would do.
   Under-scoring them to "make the correlation work" would defeat the test.

4. **Correlation.** Pairwise concordance (Goodman-Kruskal gamma) between judge score
   and outcome rank, plus the discordant pairs, plus a dedicated **load-bearing
   sub-test**: among APPROVED reviews only, can the rubric separate correct from
   wrong?

## Results

| Outcome class | n | mean judge/16 | range |
|---|---|---|---|
| `GOOD_CATCH` (right + caught a blocker) | 6 | **16.00** | 16-16 |
| `GOOD_CLEAN` (right, clean code) | 10 | 14.00 | 12-15 |
| `MISS` (wrong approval) | 3 | **13.67** | 13-15 |

- **Aggregate concordance:** 94 concordant / 9 discordant / 5 tied -> **gamma = 0.83**.
- **All discrimination lives in `GOOD_CATCH`.** Every review that flagged a real
  blocking issue scored 16/16 — but that is nearly circular: a review that says
  `BLOCKING: ...` with evidence is *both* a max catch-score *and*, by construction, a
  good outcome. The rubric isn't predicting the outcome there so much as restating it.
- **Load-bearing sub-test collapses.** Restricting to APPROVED reviews (the case the
  judge must actually grade), `GOOD_CLEAN` mean 14.00 vs `MISS` mean 13.67 — a 0.33
  gap on a 16-point scale, i.e. noise. The rubric has **no usable signal** for
  "was this approval justified?"

### The interesting failure cases

**False confidence (high score, bad outcome) — the load-bearing ones:**

- **PR #792, Rex re-review @ `2ce6708` -> scored 15/16, outcome MISS.** A long,
  table-filled, "traced + empirically confirmed", confidently-APPROVED review — of a
  commit that Hakim, reviewing the *same* commit, caught a **BLOCKING** silent
  gate-bypass in (a prefix-strip loop consumed the real create verb, so genuine
  PR-create invocations skipped validation). Rex's review is indistinguishable *on
  surface* from its correct approvals. It outscored 7 of 10 correct approvals.
- **PR #770, initial reviews -> scored 13/16, outcome MISS.** Full checklist all-Pass,
  "9/9 verified locally", APPROVED — missed a fork-scoped-query regression AND a
  **vacuous test** (the mock never checked `--repo`, so 9/9 green proved nothing). A
  later review caught both.
- **PR #767, initial review -> scored 13/16, outcome MISS.** Correctly flagged one
  non-blocking nit, radiating diligence — but missed the **blocking** GitLab-api
  merge-shape gap (the exact #47 forge analog) that the re-review raised as
  `CHANGES REQUESTED`.

**False alarm (lower score, fine outcome):** PR #677 (docs-only marker clarification)
scored 12/16 — the lowest correct approval — simply because a docs change gives a
reviewer little to "catch." The rubric penalizes reviews of low-defect diffs, which
is a property of the *diff*, not the *review*.

## Why it fails (root cause)

For an **APPROVED** review, three of the four rubric dimensions (engagement,
calibration, FP-discipline) are high *regardless of whether the approval was
correct* — a diligent-looking wrong review and a diligent right review present
identically. Only the **Catch** dimension discriminates, and Catch is
zero-information when the review (correctly or incorrectly) surfaced no blocking
finding. So the rubric can rank "flagged a blocker" above "approved," but it cannot
rank "correctly approved" above "wrongly approved" — which is the whole job.

The corpus also *flatters* the method: this repo's Rex/Hakim reviews are uniformly
high-craft (mean >= 13/16 across every class), so there is almost no genuine low end
for the rubric to correctly reject. A real `/eval-agents` corpus containing a truly
weak model would have more obvious duds the rubric *would* catch — but the weak
model's dangerous output is the *fluent-but-wrong* review, and on that class this
spike shows the surface rubric is blind.

## Answer to the flagged caveat

> Does this method catch a weak model's fluent-but-wrong reasoning, or only rank
> obviously-good vs obviously-bad reviews?

**Only the latter.** In this corpus, fluent-but-wrong is not hypothetical — PR #792
Rex @ `2ce6708` and PR #770's initial reviews are real, in-repo instances, and the
surface rubric scored them at or above the correct-approval median. A text-only
LLM-judge would hand them a passing grade.

## Recommendation for #824 (`/eval-agents`): PROCEED, but adjust the methodology

Do **not** ship a judge that scores review *prose* against a rubric. It will
rubber-stamp confident-but-wrong reviews — the exact failure mode the feature exists
to detect — while penalizing good reviews of low-defect diffs.

Instead:

1. **Ground every score in an independent verification of the diff.** The judge must
   itself be a *reviewer* (an oracle/reference review, or a stronger model actually
   re-checking the code), and score the agent on **defects-found vs defects-missed
   against ground truth**, not on rubric adherence of the text. Note that in this
   very corpus, the mechanism that *did* reliably catch the misses was a **second
   independent review of the same commit** (Hakim re-review, Rex re-review) — that is
   the shape `/eval-agents` should emulate, not a prose rater.
2. **Build the eval set from re-review disagreements + escaped bugs.** This repo hands
   you labeled data almost for free: any APPROVED commit that a later round marked
   `BLOCKING`/`CHANGES_REQUESTED`, and any merged PR followed by a `fix(#...)` on the
   same file, is a ground-truth `MISS`. Harvest those as the gold set.
3. **Report the load-bearing metric, not the aggregate.** "Can the judge separate
   correct approvals from wrong approvals?" (approve-precision) — never a single
   blended concordance number, which this spike shows hides the failure at 0.83.
4. **Keep the rubric only as a secondary, advisory signal** for review *style/craft*,
   explicitly not as the correctness oracle.

If #824 can afford an independent-verification judge, proceed. If it can only afford
a text-rubric judge, the honest call is **stop** — it would give false confidence.

## Limitations (this is a spike)

Single manual judge; n = 19; the judge was not fully blind to outcomes (mitigated by
deliberately scoring the misses high); concordance is directional evidence, not a
significance test; corpus is one repo's unusually strong review agents. Enough to
answer the go/no-go question for #824's methodology; not a measured accuracy figure.

## Reproduce

`python3 docs/spike-825/judge_calibration.py`

Raw review text was pulled with the tracker CLI (review JSON) for PRs:
792, 770, 767, 762, 748, 747, 773, 778, 787, 789, 677, 686, 688, 689, 634.

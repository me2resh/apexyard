#!/usr/bin/env python3
"""
Spike #825 — throwaway LLM-judge calibration harness.

Question: if we score the framework's review agents (Rex / Hakim) against a
rubric, do the judge scores correlate with the REAL ship/reject outcome that
already happened in this repo's PR history?

Method (see docs/spike-825/findings.md for the full write-up):
  - Labeled set = 19 real "review units" (one reviewer's assessment of one
    commit) pulled from 15 merged framework PRs.
  - judge_score = a 4-dimension rubric (0-4 each, 0-16 total) scored from the
    REVIEW TEXT ONLY -- i.e. what a surface LLM-judge that reads the review but
    does NOT independently re-review the diff would produce. Scored blind-ish to
    outcome, deliberately keeping fluent-but-wrong reviews HIGH (that is the
    whole point of the test).
  - outcome = ground truth from what actually happened next:
        GOOD_CATCH  (2) : verdict correct AND surfaced a real blocking/substantive
                          defect that was then fixed.
        GOOD_CLEAN  (1) : verdict correct on genuinely clean code (no blocking
                          defect existed; no later fix contradicted the approval).
        MISS        (0) : review APPROVED a commit that a parallel/next-round
                          review proved still carried a BLOCKING defect at (or at
                          essentially) that same commit -- the review was wrong.

We then measure rank concordance between judge_score and outcome, and call out
the discordant pairs (a high-scored review with a bad outcome = false confidence).

This is a spike: single manual judge, small N, judge not fully blind. Concordance
(Goodman-Kruskal gamma style) is used, not a p-value. It is directional evidence,
not a proof.
"""

from itertools import combinations
from statistics import mean

GOOD_CATCH, GOOD_CLEAN, MISS = 2, 1, 0
OUTCOME_NAME = {2: "GOOD_CATCH", 1: "GOOD_CLEAN", 0: "MISS"}

# (id, pr, reviewer, commit_short, [catch, engage, calib, fp], outcome, note)
DATA = [
    # ---- MISS: fluent, verification-heavy APPROVALS that were actually wrong ----
    ("R1", 792, "Rex",   "2ce6708", [3, 4, 4, 4], MISS,
     "APPROVED; missed BLOCKING shape-4 silent-bypass Hakim caught same commit"),
    ("R2", 770, "Abd",   "init",    [2, 3, 4, 4], MISS,
     "APPROVED (full checklist Pass, '9/9 verified'); missed fork-scope regression + vacuous test"),
    ("R3", 767, "Abd",   "init",    [3, 3, 3, 4], MISS,
     "APPROVED (flagged only a non-blocking nit); missed the BLOCKING glab-api half-fix (HIGH-1)"),

    # ---- GOOD_CATCH: verdict correct AND caught a real blocking/substantive bug ----
    ("R4", 792, "Hakim", "281da38", [4, 4, 4, 4], GOOD_CATCH,
     "flagged LOW multiline + MEDIUM completeness -> both became the next-round fixes"),
    ("R5", 792, "Hakim", "2ce6708", [4, 4, 4, 4], GOOD_CATCH,
     "caught the BLOCKING shape-4 verb-eating bypass"),
    ("R6", 770, "Rex",   "chg-req", [4, 4, 4, 4], GOOD_CATCH,
     "CHANGES_REQUESTED: fork-scoped query regression + false-positive test mock"),
    ("R7", 767, "RexHakim","chg-req",[4, 4, 4, 4], GOOD_CATCH,
     "CHANGES_REQUESTED: glab-api merge shape left ungated (the #47 forge analog)"),
    ("R8", 748, "Rex",   "chg-req", [4, 4, 4, 4], GOOD_CATCH,
     "CHANGES_REQUESTED: Bug-2 fix is a no-op on bash 3.2 + the test is vacuous"),
    ("R9", 762, "Abd",   "chg-req", [4, 4, 4, 4], GOOD_CATCH,
     "CHANGES_REQUESTED: cross-fork review posts to wrong repo (silent regression)"),

    # ---- GOOD_CLEAN: verdict correct on genuinely clean code ----
    ("R10", 686, "Rex", "07dc21c", [2, 3, 4, 4], GOOD_CLEAN, "jq reserved-keyword rename; correct approve"),
    ("R11", 688, "Rex", "0a54561", [2, 4, 4, 4], GOOD_CLEAN, "cd-target re-root; adversarial verify; correct"),
    ("R12", 689, "Rex", "c00e644", [3, 4, 4, 4], GOOD_CLEAN, "merge-gate re-root; flagged latent follow-up; correct"),
    ("R13", 634, "Rex", "10969b1", [3, 4, 4, 4], GOOD_CLEAN, "push-ref regex; full edge-case table; correct"),
    ("R14", 789, "Rex", "bc429fb", [2, 4, 4, 4], GOOD_CLEAN, "agent-role rule; diff-scope verified; correct"),
    ("R15", 677, "Rex", "c96238b", [1, 3, 4, 4], GOOD_CLEAN, "docs-only marker clarification; correct (little to catch)"),
    ("R16", 747, "Rex", "chg?",    [3, 4, 4, 4], GOOD_CLEAN, "active-ticket re-root; proved regression by revert; correct"),
    ("R17", 773, "Hakim","final",  [3, 3, 4, 4], GOOD_CLEAN, "agdr-arch-pr diff base; injection-clean; correct"),
    ("R18", 778, "Rex", "final",   [2, 4, 4, 4], GOOD_CLEAN, "security-auditor trust-chain trigger; regression-free; correct"),
    ("R19", 787, "Rex", "final",   [2, 4, 4, 4], GOOD_CLEAN, "isolated-builds rule; wiring guard passes; correct"),
]


def judge(row):
    return sum(row[4])  # row = (id, pr, reviewer, commit, dims, outcome, note)


def concordance(rows):
    """Goodman-Kruskal style: over all pairs with DIFFERENT outcome ranks,
    fraction where the higher-outcome review also has the higher judge score."""
    conc = disc = tie = 0
    inversions = []
    for a, b in combinations(rows, 2):
        oa, ob = a[5], b[5]
        if oa == ob:
            continue
        ja, jb = judge(a), judge(b)
        better = a if oa > ob else b       # the one that SHOULD score higher
        worse = b if oa > ob else a
        jb_better, jb_worse = judge(better), judge(worse)
        if jb_better > jb_worse:
            conc += 1
        elif jb_better < jb_worse:
            disc += 1
            inversions.append((worse, better))  # worse-outcome outscored better-outcome
        else:
            tie += 1
    gamma = (conc - disc) / (conc + disc) if (conc + disc) else 0.0
    return conc, disc, tie, gamma, inversions


def main():
    rows = DATA
    print(f"Labeled review units: {len(rows)}\n")
    print(f"{'ID':<4}{'PR':<5}{'rev':<9}{'judge/16':<9}{'outcome':<12}note")
    for r in sorted(rows, key=lambda x: (-judge(x), x[5])):
        print(f"{r[0]:<4}{r[1]:<5}{r[2]:<9}{judge(r):<9}{OUTCOME_NAME[r[5]]:<12}{r[6][:60]}")

    by = {2: [], 1: [], 0: []}
    for r in rows:
        by[r[5]].append(judge(r))
    print("\nMean judge score by outcome class:")
    for k in (2, 1, 0):
        s = by[k]
        print(f"  {OUTCOME_NAME[k]:<12} n={len(s):<3} mean={mean(s):.2f}  range={min(s)}-{max(s)}")

    conc, disc, tie, gamma, inv = concordance(rows)
    print(f"\nPairwise concordance (different-outcome pairs only):")
    print(f"  concordant={conc}  discordant={disc}  tied={tie}")
    print(f"  Goodman-Kruskal gamma = {gamma:.2f}   (1.0=perfect, 0=chance, -1=inverted)")

    print(f"\nDiscordant pairs (worse OUTCOME scored >= better outcome by the judge) "
          f"= false-confidence cases:")
    for worse, better in inv:
        print(f"  judge scored {worse[0]}({OUTCOME_NAME[worse[5]]},{judge(worse)}) "
              f">= {better[0]}({OUTCOME_NAME[better[5]]},{judge(better)})")

    # The specifically load-bearing test: can the judge separate CORRECT approvals
    # from WRONG approvals? (i.e. among APPROVED reviews, GOOD_CLEAN vs MISS)
    approvals = [r for r in rows if r[5] in (GOOD_CLEAN, MISS)]
    clean = [judge(r) for r in approvals if r[5] == GOOD_CLEAN]
    miss = [judge(r) for r in approvals if r[5] == MISS]
    print("\nLOAD-BEARING SUB-TEST — among APPROVED reviews, can the rubric tell "
          "correct from wrong?")
    print(f"  GOOD_CLEAN (correct approve) mean={mean(clean):.2f} range={min(clean)}-{max(clean)}")
    print(f"  MISS       (wrong approve)   mean={mean(miss):.2f} range={min(miss)}-{max(miss)}")
    top_miss = max(miss)
    beaten = [j for j in clean if j < top_miss]
    print(f"  -> the single most-fluent MISS scored {top_miss}/16, HIGHER than "
          f"{len(beaten)}/{len(clean)} genuinely-correct approvals.")


if __name__ == "__main__":
    main()

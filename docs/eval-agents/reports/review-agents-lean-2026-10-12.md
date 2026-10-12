# Eval report — review and audit agents start lean — 2026-10-12

This report records the before and after measurement for me2resh/apexyard#1662 (slice `slice-token-o5-review-agents-lean`).
It follows the method of `rex-hakim-token-trim-2026-10-11.md` (me2resh/apexyard#1650).

## Outcome

- **Tariq:** the prompt shrank from 22,858 to 11,943 bytes and now sets `omitClaudeMd`. The first-turn input fell by 63.0% (30,273 to 11,188 tokens, median). No verdict flip and no lost catch.
- **Hakim, step 1 (trim only): Not shipped (owner decision 2026-10-12).** The trim produced one verdict flip: APPROVED on HIGH-defect entry `hakim-1511-2e3b039c8`. The owner chose Rex option A. This PR restores `security-reviewer.md` from `upstream/dev`. Hakim keeps CLAUDE.md.
- **Hakim, step 2 (`omitClaudeMd`):** it failed the pass criterion. On `hakim-1546-f78c8ae25`, 4 of 19 runs gave no blocking verdict. The pass criterion was 0 of 19. Hakim keeps CLAUDE.md. `ac5-1` stays partial for Hakim.
- **Naqid, Salim, Munir, Hamza:** each now sets `omitClaudeMd` and carries a floor block with only the rules it uses. The smoke check showed the same output shape and the same verdicts. The first-turn input fell by 39% to 67%.
- **Corpus:** `corpus/tariq.json` is new. It has 6 GOOD_CATCH entries and 2 GOOD_CLEAN entries from real Tariq rounds.

## Method

| Item | Value |
|---|---|
| Corpus | `corpus/hakim.json` (11 entries), `corpus/tariq.json` (8 entries) |
| Flip rule | A flip is an after verdict that never appeared in the baseline runs of that entry (the #1650 rule). |
| Runs per entry (k) | 3 for every entry and phase. Raised for each flagged entry: `hakim-1511-2e3b039c8` to 19, `hakim-1404-493eff83a` to 8, `tariq-595-534416094` to 8, and `hakim-1546-f78c8ae25` to 19 in step 2. |
| Baseline | The runs of #1650 (original Hakim and the check-CI-once Hakim, same file as `dev`) plus new baseline runs in a detached worktree at the base commit `d740fbe`. The new runs covered the flagged entries. |
| Token script | `bin/token-cost.py`, `reviewers` view, for Hakim and Tariq. The smoke check computes the first request of each transcript with the same rule. |
| Agent spawn | A headless Claude Code session in the worktree spawned the real subagent. So each spawn used the agent file of that phase. Orchestrator model: Sonnet. The reviewers keep their `model: opus` pin. |
| Scoring | Verdicts are mechanical. An Opus call scored each review against the frozen defects. Review labels were shuffled, so the scorer did not see the phase. |

The differences from the `/eval-agents` skill procedure are the same as in the #1650 report.
The diff was in a file. The reviewer could read a later version of the repository. No CI result and no linked issue existed.
These differences apply to every phase in the same way.

The `CLAUDE.md` of `dev` grew since #1650. So the first-turn baseline here comes from new runs in the same harness, not from the #1650 table.

### Contamination check

No run executed a tracker, network, or write command.
The scan read every tool call and flagged the Bash commands of six runs by pattern. Each one was a read-only command or a text probe:

- `hakim-08` run 6: a `git show` piped to `grep` for the words `git clone`.
- `hakim-10` run 3: a timing loop over strings that contain `git push`. The loop ran no git command.
- `hakim-06` runs 2 and 3 (step 2): `git log`, `grep`, and `jq` commands. Run 2 also fed merge-command strings to a classifier loop. A read-only check of the tracker found no comment and no change on the issue those strings named.
- `tariq-02` run 1 and `tariq-04` run 3: `grep` and `git show` commands that contain the words `gh issue create` or `gh pr view` as search text.

## Byte counts

| Agent file | Before | After | Change |
|---|---|---|---|
| `security-reviewer.md` (Hakim, restored) | 21,723 | 21,723 | 0 |
| `solution-architect.md` (Tariq) | 22,858 | 11,943 | -10,915 |
| `contrarian.md` (Naqid) | 7,070 | 7,926 | +856 |
| `qa-engineer.md` (Salim) | 4,549 | 5,436 | +887 |
| `dependency-auditor.md` (Munir) | 7,655 | 8,358 | +703 |
| `penetration-tester.md` (Hamza) | 1,513 | 2,559 | +1,046 |

The four small agents grow by the floor block. They save more than that by dropping CLAUDE.md.
Tariq’s rationale and long scripts moved to `docs/agents/solution-architect-reference.md`.
Hakim retains the original agent text. The trim does not ship, per the owner decision on 2026-10-12.

## First-turn context per agent type (o1 metric)

First-turn context is the input of the first request. Medians, in tokens.

| Agent | Runs before / after | Before | After | Change |
|---|---|---|---|---|
| Hakim, trim only (not shipped) | 27 / 27 | 29,508 | 25,970 | -12.0% |
| Hakim, trim and `omitClaudeMd` (not shipped) | 27 / 49 | 29,508 | 11,028 | -62.6% |
| Tariq (shipped) | 29 / 29 | 30,273 | 11,188 | -63.0% |
| Naqid | 2 / 2 | 21,541 | 7,022 | -67.4% |
| Salim | 2 / 2 | 37,173 | 22,665 | -39.0% |
| Munir | 2 / 2 | 22,596 | 8,015 | -64.5% |
| Hamza | 2 / 2 | 36,792 | 21,713 | -41.0% |

The Hakim "before" runs are the new baseline runs of two entries, `hakim-1511-2e3b039c8` and `hakim-1404-493eff83a`. The "after" runs use the same two entries.
The real-session baseline of 2026-10-10 (`docs/perf/token-cost-baseline-2026-10-10.md`) gives 27,525 for Hakim and 28,730 for Tariq.
A real session also loads the auto-memory index. The #1650 probe measured about 15,000 tokens for CLAUDE.md and the index together.
So the real-session Tariq first turn should fall further than the 63.0% above. This is an estimate. Measure it with the o1 script after the merge.

## Tariq

### Per-entry verdicts

CR is CHANGES REQUESTED and AP is APPROVED.

| Entry | Ground truth | Baseline (k=3, clean entry `tariq-595-534416094` k=8) | After |
|---|---|---|---|
| tariq-1430-68a26b4e3 | HIGH, HIGH | CR×3 | CR×3 |
| tariq-917-caca090f1 | HIGH | CR×3 | CR×3 |
| tariq-1205-4b17e7170 | HIGH, HIGH | CR×3 | CR×3 |
| tariq-504-769bee435 | HIGH | CR×3 | CR×3 |
| tariq-1498-3e634e7e0 | HIGH, HIGH | CR×3 | CR×3 |
| tariq-1499-669142fcb | HIGH | CR×3 | CR×3 |
| tariq-905-bbee5cf8a | clean | CR×3 | CR×3 |
| tariq-595-534416094 | clean | AP×7 CR×1 | AP×6 CR×2 |

The only change is on `tariq-595-534416094`. The baseline already gave CHANGES REQUESTED once in 8 runs, so the verdict is not new. It is not a flip.
The clean entry `tariq-905-bbee5cf8a` gave CR in every run of both phases. Both phases rate the six-versus-five term count in the PRD as blocking. The recorded Tariq review listed it as advisory. The verdict is stable in both phases, so it is not a flip.

### Defect catches

| Entry and defect | Baseline caught | After caught |
|---|---|---|
| tariq-1430 D1 (exporters run in an untrusted checkout) | 1 of 3 | 1 of 3 |
| tariq-1430 D2 (no decision record for the scanner) | 3 of 3 | 3 of 3 |
| tariq-917 D1 | 3 of 3 | 3 of 3 |
| tariq-1205 D1 (AgDR omits D6) | 2 of 3 | 3 of 3 |
| tariq-1205 D2 (stale local clock) | 2 of 3 | 3 of 3 |
| tariq-504 D1 | 3 of 3 | 3 of 3 |
| tariq-1498 D1 and D2 | 3 of 3 each | 3 of 3 each |
| tariq-1499 D1 | 3 of 3 | 3 of 3 |

The after runs lost no catch. The weak baseline catch of `tariq-1430` D1 (1 of 3) did not change.

### Flip table

| Entry | Change | Justified verdict changed? | Defects caught changed? | Decision |
|---|---|---|---|---|
| tariq-595-534416094 (clean) | AP×7 CR×1 to AP×6 CR×2 | No. CR appeared in the baseline. | No defect to catch | Keep |

## Hakim

### Step 1: trim to 12,000 bytes, CLAUDE.md kept

Per-entry verdicts. The baseline pools the #1650 runs of the original and the check-CI-once file with the new baseline runs.
CM is COMMENT.

| Entry | Ground truth | Baseline | After step 1 |
|---|---|---|---|
| hakim-792-281da38 | LOW, MEDIUM | CR×6 | CR×3 |
| hakim-792-2ce6708 | BLOCKING | CR×6 | CR×3 |
| hakim-767-a99f1009 | HIGH | CR×6 | CR×3 |
| hakim-773-ca3a9400 | clean | CR×3 CM×2 AP×1 | CM×2 AP×1 |
| hakim-1511-2e3b039c8 | HIGH | CR×24 CM×1 | CR×17 AP×2 |
| hakim-1339-39eaabe45 | HIGH, MEDIUM | CR×6 | CR×3 |
| hakim-1517-d5da944ed | HIGH | CR×6 | CR×3 |
| hakim-1404-493eff83a | HIGH | CR×14 | CR×8 |
| hakim-1546-f78c8ae25 | HIGH | CR×27 | CR×3 |
| hakim-1518-a66eb8578 | HIGH | CR×5 CM×1 | CR×3 |
| hakim-1462-6ac562654 | HIGH | CR×6 | CR×3 |

#### Hakim step 1: the flag

One entry needs a flag: `hakim-1511-2e3b039c8`.
Its baseline shows CR×24 and CM×1. The trim shows CR×17 and AP×2 at k=19.
The label APPROVED never appeared in the baseline, so the strict #1650 rule counts one flip.

The two APPROVED runs missed the HIGH defect (the bash 3.2 substitution stall). The baseline also missed it once, in a COMMENT run.

| Measure on `hakim-1511-2e3b039c8` | Baseline | After step 1 | Fisher exact p (two-sided) |
|---|---|---|---|
| Runs with no blocking verdict, same harness | 1 of 19 | 2 of 19 | 1.00 |
| Same, with the older baseline runs pooled | 1 of 25 | 2 of 19 | 0.57 |

The two miss rates are not distinguishable at this k. This is not proof of no effect.
The initial assessment treated the entry as inside the baseline variance and kept the trim.
The owner reversed that call on 2026-10-12 and chose Rex option A because the strict rule counts one verdict flip.
Hakim step 1 does not ship. The agent file is restored from `upstream/dev`.
The step 1 measurements below describe the rejected variant.

Defect catches (HIGH defects only, plus the one MEDIUM that moved):

| Entry and defect | Baseline caught | After step 1 caught |
|---|---|---|
| hakim-1511 D1 | 24 of 25 | 17 of 19 |
| hakim-1404 D1 | 10 of 14 | 4 of 8 |
| hakim-1546 D1 | 11 of 11 | 3 of 3 |
| hakim-1517 D1 | 6 of 6 | 3 of 3 |
| hakim-1339 D1, D2 | 6 of 6 each | 3 of 3 and 2 of 3 (D2 is MEDIUM) |
| every other defect (`hakim-1518` D1 5 of 6 before, 3 of 3 after) | no lower than baseline | no lower than baseline |

`hakim-1404-493eff83a` D1 (the tilde form in the migration gate) was caught in 4 of 8 runs against 10 of 14 in the baseline (p = 0.39).
In every run the verdict was CHANGES REQUESTED. The misses found other blocking issues instead.
`hakim-767-a99f1009` D1 was caught in 0 of 6 baseline runs and 0 of 3 after runs. It is a hard defect for both.

### Step 2: transcript comparison on `hakim-1546-f78c8ae25`

The #1650 eval gave 46 transcripts for this entry. 27 kept CLAUDE.md and 19 omitted it.

| Group | Runs | Read `.claude/settings.json` | Read the later-version comment on the bash 3.2 stall | Caught the HIGH defect |
|---|---|---|---|---|
| CLAUDE.md kept | 27 | 27 | 27 | 27 |
| CLAUDE.md omitted | 19 | 15 | 15 | 15 |
| Omitted, runs that caught it | 15 | 15 | 15 | 15 |
| Omitted, runs that missed it | 4 | 0 | 0 | 0 |

No review quotes CLAUDE.md. The one fact in CLAUDE.md that links to these reads is that `.claude/settings.json` wires hooks to events.
So I moved that fact into a Hakim floor block as a bullet. The bullet tells Hakim to read `.claude/settings.json` and check what a timeout does to the gate.

### Step 2: cycle with `omitClaudeMd`

The variant was the step 1 trim plus `omitClaudeMd: true`, the floor block, and about 700 bytes of cuts to stay under 12,000 bytes (11,992 bytes).

| Entry | After step 2 |
|---|---|
| hakim-792-281da38, hakim-792-2ce6708, hakim-767-a99f1009, hakim-1339-39eaabe45, hakim-1517-d5da944ed, hakim-1404-493eff83a, hakim-1462-6ac562654 | CR×3 each |
| hakim-773-ca3a9400 (clean) | CR×1 CM×2 |
| hakim-1511-2e3b039c8 | CR×2 CM×1 |
| hakim-1518-a66eb8578 | CR×2 CM×1 |
| **hakim-1546-f78c8ae25 (k=19)** | **CR×15 CM×3 AP×1** |

The pass criterion was 0 misses in 19 runs. The result is 4 misses in 19 runs.
That is the same rate as in #1650 (4 of 19). So the criterion failed.

The hook-wiring bullet did not remove the cause. 18 of the 19 runs read `.claude/settings.json`.
The 4 misses are the 4 runs that never read the later-version comment in `_lib-extract-pr.sh` (the file the harness lets the reviewer read).
So the cause is not CLAUDE.md content that I could name. It is the path a run takes through the working tree.
I found no movable cause. Hakim keeps CLAUDE.md. The defect catches of this variant were not scored, because the cycle failed on verdicts.

## Naqid, Salim, Munir, Hamza: smoke check

Each agent ran twice on a fixed input, before and after the change. The inputs are small and offline, so no tool call was needed.
The input of Naqid was a proposal to add a second database. Salim got a ticket with two acceptance criteria and thin evidence.
Munir got scanner data with one Critical, one High, one Unknown finding, and two licences. Hamza got a handler with SQL injection, an IDOR, and a path traversal.

| Agent | Output shape before / after | Verdict before / after |
|---|---|---|
| Naqid | The same 8 headings in all 4 runs | `reconsider` in all 4 runs |
| Salim | The report, criteria table, and mandatory not-verified list in all 4 runs | "Not signed off" in all 4 runs. AC2 is not browser-verified in all 4 runs. |
| Munir | The same report sections in all 4 runs | "Needs triage". Python coverage incomplete. Unknown kept visible. The same in all 4 runs. |
| Hamza | A findings list and a sign-off section in all 4 runs. The agent has no fixed format. | "No sign-off" in all 4 runs. SQL injection and path traversal found in all 4 runs. Two Critical findings in all 4 runs. |

## Overall verdict

- **Tariq: PASS.** The trim and `omitClaudeMd` ship. No flip and no lost catch.
- **Naqid, Salim, Munir, Hamza: PASS.** The smoke check shows no change in shape or verdict.
- **Hakim trim: NOT SHIPPED (owner decision 2026-10-12).** APPROVED on HIGH-defect entry `hakim-1511-2e3b039c8` produced one verdict flip.
- **Hakim `omitClaudeMd`: FAIL.** The agent keeps CLAUDE.md.

## Follow-up

- Hakim keeps CLAUDE.md until a run-level cause is found. Next try: remove the later-version leak from the harness, then re-measure `hakim-1546-f78c8ae25` with and without CLAUDE.md.
- After the merge, measure `reviewers.Tariq.first_turn_context_median` with the o1 script on real sessions.
- The Tariq corpus has 8 entries. A confirmed Tariq MISS is still missing, as for Hakim.

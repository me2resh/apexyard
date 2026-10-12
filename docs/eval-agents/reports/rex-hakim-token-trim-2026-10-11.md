# Eval report — Rex and Hakim token trim — 2026-10-11

This report records the before and after measurement for me2resh/apexyard#1650 (slice `slice-harness-o4-review-agent-token-trim`).

## Outcome

- **Rex:** `omitClaudeMd`, a floor-rules block, and a prompt trim cut the first-turn input by 38.2% (43,390 to 26,813 tokens, median).
- **Rex quality:** no per-entry change in the justified verdict or in the defects caught. Two clean entries changed verdict label once each, inside the approve class or toward the justified verdict.
- **Hakim:** `omitClaudeMd` and a floor block cut the first-turn input by 36.7%. But Hakim then missed a HIGH defect on one entry in 4 of 19 runs. The baseline missed it in 0 of 19 runs. So the Hakim change was reverted.
- **Hakim as shipped:** the original prompt plus the one check-CI-once line. It showed no flip in the justified verdict and no lost catch.
- **Corpus:** `corpus/hakim.json` grew from 4 to 11 entries.

## Method

| Item | Value |
|---|---|
| Corpus | `corpus/rex.json` (10 entries), `corpus/hakim.json` (11 entries) |
| Runs per entry (k) | 3 for every entry and phase. Raised to 8 for each entry that changed, and to 19 for `hakim-1546-f78c8ae25`. |
| Token script | `bin/token-cost.py` (the o1 script), `reviewers` view and `compare`, at commit `7d314c0` |
| Agent spawn | A headless Claude Code session in the slice worktree spawned the real `code-reviewer` or `security-reviewer` subagent. So each spawn used the agent file of that phase. |
| Orchestrator model | Sonnet. The reviewers keep their `model: opus` pin. |
| Scoring | Verdicts are mechanical. A blinded scorer matched defects against the frozen key. Disputed rows were adjudicated by hand (see "Defect catches"). |

### Choice of k

The baseline at k=3 showed run-to-run variance on 2 of 21 entries (`hakim-773-ca3a9400` and `hakim-1518-a66eb8578`).
That rate is low, so k=3 was enough to detect a change.
The flip rule was set before the after runs. A flip is an after verdict that never appeared in the baseline runs of that entry.
Each flagged entry then got 5 more runs in both phases (k=8), so the decision did not rest on 3 samples.

### Differences from the `/eval-agents` skill procedure

These differences apply to every phase in the same way. They do not bias the comparison.

- The diff was in a file that the reviewer read. The skill puts the diff inline in the prompt. The file kept the first-turn context free of the diff, so that metric shows the prompt cost only.
- The permission allowlist gave the reviewer read-only tools only. It allowed Read, Grep, Glob, and read-only `git` commands. A Bash timing probe was not possible.
- The reviewer could read a later version of the repository. A few reviews used a later fix comment as evidence.
- No CI result and no linked issue existed. Rex therefore requests changes on most clean entries (for example, no Glossary is visible). This is the same in every phase.
- The headless sessions loaded no auto-memory index. Real sessions in the ops fork also load the memory index. See "Expected saving in real sessions".

### Contamination check

No run executed a tracker, network, or write command.
The scan read every tool call in every subagent transcript and ignored calls that the permission system or a hook denied.
One baseline run (`hakim-792-281da38`, run 1) matched the pattern, but the match was a `grep` pattern string, not a command.
No file under `.claude/session/reviews/` changed because of an eval run.

## Token use per review (k=3, every entry)

First-turn context is the input of the first request: system prompt, agent prompt, tool schemas, and the eval prompt.
It is the stable measure of the prompt cost.
Total tokens and cache-read tokens follow the counting rules in `docs/perf/token-cost.md`.

| Agent and variant | Runs | First-turn context, median | Total tokens, median / mean | Cache-read tokens, mean per review |
|---|---|---|---|---|
| Rex, before | 30 | 43,390 | 37,509 / 38,163 | 423,050 |
| **Rex, after (shipped)** | 30 | **26,813 (-38.2%)** | 32,756 / 31,319 (-17.9% mean) | 314,785 (-25.6%) |
| Hakim, before | 33 | 23,673 | 55,137 / 52,055 | 363,223 |
| Hakim, with `omitClaudeMd` and floor block (reverted) | 33 | 14,975 (-36.7%) | 38,508 / 38,607 | 291,672 |
| **Hakim, check-CI-once line only (shipped)** | 33 | **23,782 (+0.5%)** | 44,876 / 46,471 | 331,478 |

Total tokens of one Hakim variant moved by about 18% between batches with an identical first turn.
So treat a change in total tokens below about 20% as run-to-run noise.

Rex first-turn saving by source, from the paired runs:

- CLAUDE.md removed: about 9,100 tokens. The Hakim variant isolates this number.
- Prompt trim: the agent file went from 73,140 to 53,965 bytes. That is about 7,900 tokens.
- The floor block adds about 400 tokens back.

### Expected saving in real sessions

A probe in the ops fork spawned one minimal custom agent twice: once with `omitClaudeMd` and once without.
The first-turn context fell from 17,408 to 2,453 tokens.
So in a real session, `omitClaudeMd` removes about 15,000 tokens: CLAUDE.md and the auto-memory index.
The probe also confirms that `omitClaudeMd` drops the memory index for a custom agent.

The 2026-10-10 baseline (`docs/perf/token-cost-baseline-2026-10-10.md`) gives a Rex first-turn median of 49,107 tokens.
The expected Rex first-turn median after this change is about 26,500 tokens, a drop of about 46%.
This is an estimate. Measure it with the o1 script on real sessions after the merge (metric `reviewers.Rex.first_turn_context_median`).

## Per-entry verdicts

CR is CHANGES REQUESTED, AP is APPROVED, and CM is COMMENT.
The "k=3" columns use runs 1 to 3. The "all runs" columns add the extra runs.

### Rex

| Entry | Ground truth | Before, k=3 | After, k=3 | Before, all runs | After, all runs |
|---|---|---|---|---|---|
| rex-792-2ce6708 | BLOCKING | CR×3 | CR×3 | CR×3 | CR×3 |
| rex-770-6b19e2b5a | BLOCKING, MEDIUM | CR×3 | CR×3 | CR×8 | CR×8 |
| rex-767-a99f1009 | HIGH | CR×3 | CR×3 | CR×3 | CR×3 |
| rex-748-007f527c | HIGH, MEDIUM | CR×3 | CR×3 | CR×3 | CR×3 |
| rex-686-07dc21c | clean | AP×3 | AP×2 CM×1 | AP×8 | AP×6 CM×2 |
| rex-677-c96238b | clean | CR×3 | CR×3 | CR×3 | CR×3 |
| rex-773-ca3a9400 | clean | CR×3 | CR×3 | CR×3 | CR×3 |
| rex-778-64c3ff5 | clean | CR×3 | CR×3 | CR×3 | CR×3 |
| rex-787-512d253 | clean | CR×3 | CR×2 AP×1 | CR×8 | CR×7 AP×1 |
| rex-1289-9382269f | HIGH | AP×3 | AP×3 | AP×3 | AP×3 |

### Hakim

| Entry | Ground truth | Before, k=3 | Reverted variant, k=3 | Shipped, k=3 | Before, all runs | Reverted variant, all runs | Shipped, all runs |
|---|---|---|---|---|---|---|---|
| hakim-792-281da38 | LOW, MEDIUM | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-792-2ce6708 | BLOCKING | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-767-a99f1009 | HIGH | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-773-ca3a9400 | clean | CR×1 CM×2 | CR×2 CM×1 | CR×2 AP×1 | CR×1 CM×2 | CR×2 CM×1 | CR×2 AP×1 |
| hakim-1511-2e3b039c8 | HIGH | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-1339-39eaabe45 | HIGH, MEDIUM | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-1517-d5da944ed | HIGH | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-1404-493eff83a | HIGH | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |
| hakim-1546-f78c8ae25 | HIGH | CR×3 | CR×1 CM×2 | CR×3 | CR×19 | CR×15 CM×4 | CR×8 |
| hakim-1518-a66eb8578 | HIGH | CR×2 CM×1 | CR×2 CM×1 | CR×3 | CR×2 CM×1 | CR×2 CM×1 | CR×3 |
| hakim-1462-6ac562654 | HIGH | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 | CR×3 |

The reverted-variant "all runs" column for `hakim-1546-f78c8ae25` pools three batches of the same omitted-CLAUDE.md prompt (8 + 8 + 3 runs).

## Flip table

A flip is an after verdict that never appeared in the baseline runs of that entry.

| Entry | Change | Justified verdict changed? | Defects caught changed? | Decision |
|---|---|---|---|---|
| rex-686-07dc21c (clean) | AP×8 to AP×6 CM×2 | No. COMMENT and APPROVED are both justified on a clean entry. | No (no defect to catch) | Keep. Each COMMENT run said it would approve once CI is green. |
| rex-787-512d253 (clean) | CR×8 to CR×7 AP×1 | No for 7 runs. The one APPROVED run moved to the justified verdict. | No (no defect to catch) | Keep |
| hakim-1546-f78c8ae25 (HIGH) | CR×19 to CR×15 CM×4 | Yes. COMMENT on a HIGH defect is not justified. | Yes. The HIGH defect was missed or rated LOW in 4 of 19 runs, against 0 of 19. | **Revert** `omitClaudeMd` and the floor block in Hakim |
| hakim-773-ca3a9400 (clean), shipped Hakim | CR, CM to CR×2 AP×1 | No. APPROVED is the justified verdict on a clean entry. | No (no defect to catch) | Keep |

### How the Hakim cause was isolated

1. The first suspect was the check-CI-once line, because each COMMENT run cited "CI absent".
2. A variant without that line (CLAUDE.md still omitted) gave CR×8, then CM×2 CR×1 in a fresh batch. The line was not the cause.
3. A variant with only that line (CLAUDE.md kept) gave CR×8 on `hakim-1546-f78c8ae25`. Every run named the bash 3.2 substitution defect.
4. So the cause is the omitted CLAUDE.md. The mechanism is not known. CLAUDE.md does not mention bash 3.2.

## Defect catches

A blinded scorer matched each review against the frozen defects. Hand adjudication corrected three cases:

- `hakim-1546-f78c8ae25`: the scorer marked all runs as caught. Two COMMENT runs did not name the bash 3.2 substitution. A third rated a "possible timeout risk, unmeasured" as LOW. These count as misses.
- `rex-770-6b19e2b5a` D2 (the test mock ignores `--repo`): the scorer marked one after run as missed. That run states "the gh stub ignores its arguments". D2 was caught in 8 of 8 runs in both phases.
- `rex-748-007f527c` D1 and D2 (bash 3.2 specifics): the scorer marked most runs as caught. No run in either phase named bash 3.2. Both phases caught 0 of 3. The runs found other blocking issues.

With these corrections, no Rex entry lost a catch, and the shipped Hakim lost no catch.

## Overall verdict

**PASS for the shipped files.** Rex input per review drops by 38.2% at the first turn and by 25.6% in cache reads. Justified verdicts and catches do not change.
Hakim keeps CLAUDE.md, because omitting it lost a HIGH-defect catch beyond the measured variance.
The Hakim token saving moves to a later cycle (see "Follow-up").

## Follow-up

- Hakim needs a longer floor block, or a corpus probe that shows which CLAUDE.md content it uses, before `omitClaudeMd` can return. The token plan's o5 already owns the Hakim prompt trim.
- After the merge, measure `reviewers.Rex.first_turn_context_median` on real sessions with the o1 script.

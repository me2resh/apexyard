# Rex flip table — blind-spot checks — #1798

Shape-probe and recount checks for two known Rex blind spots.

Status: **Targeted eval, the C4 no-flip run, the no-flip re-run and the rex-773 k=8 run, 2026-10-19. Two flips remain with prompt `a7b3`. The CEO accepted both ([#1798 comment](https://github.com/me2resh/apexyard/issues/1798#issuecomment-6279094760)): rex-773 (COMMENT to CHANGES REQUESTED, borderline) and rex-1711 (COMMENT to APPROVED, toward the frozen key). rex-1683 does not flip.**

Prompt hashes (SHA-256, first 12 hex):

- Baseline (the PR #1797 prompt): `2656e3532425`
- After the first #1798 edit: `3cc6d04fb7ed`
- After the second #1798 edit: `1ac8b6976d53`
- After the third #1798 edit (the unverifiable-claim sentence removed): `a7b38bd17fe3`

Protocol: the same as the #1773 partial protocol.
Opus CLI, no tools, an empty scratch folder outside any repo.
The reviewer got the sanitized delta diff, the sanitized earlier review, and the delta range.
It got no PR number, repo name, or tracker reference.
Scoring: a defect counts as caught only when a finding names it as blocking.
A hint, a suggestion, or an "Unverified" note counts as missed.

| Entry | Frozen defect | Baseline 6 runs | After edit 1 `3cc6` k=3 | After edit 2 `1ac8` k=3 |
|---|---|---|---|---|
| rex-1765-31e0fd03-delta | D1 (a variable inside a redirect target hides a merge) | 0/6 caught, all APPROVED | 2/3 caught with CHANGES REQUESTED (k1, k3); k2 APPROVED | Not run |
| rex-1620-6229f1c-delta | D1 (the notes claim 24 walk-ups; the source has 18) | 0/6 | 0/3 (k1 lists the claim as Unverified; k3 names it as a mismatch without a blocking verdict) | 0/3 (k1 suggestion only; k3 accepts the count) |
| rex-1620-6229f1c-delta | D2 (the Bedrock setting is missing) | 0/6 | 0/3 | 2/3 caught as blocking kind 3 (k2, k3) |

## Acceptance criteria — #1798

| Criterion | Result | Evidence |
|---|---|---|
| AC1 | Met | 2 of 3 runs catch the redirect-target merge hide |
| AC2 | Partly met, accepted by the CEO | rex-1620 D1: 0 of 3 with `a7b3`. rex-1620 D2: 1 of 3 with `a7b3` against 0 of 6 for the baseline. The recount and settings work continues in #1815 ([CEO decision](https://github.com/me2resh/apexyard/issues/1798#issuecomment-6279094760)) |
| AC3 (no flip on the other 13 entries) | Met with two accepted exceptions | rex-773 flips at k=8: baseline 6 C, 2 CR; `a7b3` 1 C, 7 CR. rex-1711 flips from C (majority) to A, toward the frozen key. rex-1683 does not flip. The CEO accepted both flips. The other 10 entries were not re-run with `a7b3` |
| AC4 | Met | The `/code-review` cap is 15,736 of 16,000 bytes; `test_token_efficiency_wave1.sh` passes |

Limit: the eval gives Rex no tools, so it cannot recount a number against the source.
Follow-up #1815 tests the recount check with read-only source access.

## No-flip table (C4)

Prompts: baseline `2656e3532425` (the prompt of PR #1797), and new `1ac8b6976d53`.
Protocol: the same as above. Opus CLI, no tools, k=3 per prompt and entry, 13 entries (the 15 corpus entries minus the two blind-spot entries).
Non-delta entries got the sanitized diff only. Delta entries also got the sanitized earlier review and the delta range.
Baseline run 1 of rex-1683, rex-1711 and rex-1769 is an earlier #1773 run at the same prompt. All other runs are new.
Scoring: a defect counts as caught only when a finding names it as blocking.
A false alarm (FA) is a run that has a blocking finding with no frozen defect behind it. The count is runs of 3, not findings.
A flip is a change in the majority verdict between the two prompts.
A, C and CR in the verdict columns are APPROVED, COMMENT and CHANGES REQUESTED.

| Entry | Frozen key | Baseline verdicts | New verdicts | Defects caught, baseline | Defects caught, new | FA runs, baseline | FA runs, new | Flip |
|---|---|---|---|---|---|---|---|---|
| rex-792-2ce6708 | A (D1 missed in record) | CR, CR, C | CR, CR, CR | D1 2/3 | D1 3/3 | 2 | 3 | No |
| rex-770-6b19e2b5a | CR (D1, D2) | CR, CR, CR | CR, CR, CR | D1 3/3, D2 3/3 | D1 3/3, D2 3/3 | 1 | 2 | No |
| rex-767-a99f1009 | A (D1 missed in record) | CR, CR, CR | CR, CR, CR | D1 0/3 | D1 0/3 | 3 | 3 | No |
| rex-748-007f527c | CR (D1, D2) | CR, CR, CR | CR, CR, CR | D1 0/3, D2 0/3 | D1 0/3, D2 0/3 | 3 | 3 | No |
| rex-686-07dc21c | A | CR, CR, CR | CR, CR, CR | none to catch | none to catch | 3 | 3 | No |
| rex-677-c96238b | A | CR, CR, CR | CR, CR, CR | none to catch | none to catch | 3 | 3 | No |
| rex-773-ca3a9400 | A | C, C, CR | CR, CR, CR | none to catch | none to catch | 1 | 3 | **Yes** (C to CR) |
| rex-778-64c3ff5 | A | C, C, C | C, C, C | none to catch | none to catch | 0 | 0 | No |
| rex-787-512d253 | A | CR, CR, CR | CR, CR, CR | none to catch | none to catch | 3 | 3 | No |
| rex-1289-9382269f | A (D1 missed in record) | CR, CR, CR | CR, CR, CR | D1 0/3 | D1 0/3 | 3 | 3 | No |
| rex-1683-f85a154-delta | A | A, A, A | CR, CR, CR | none to catch | none to catch | 0 | 3 | **Yes** (A to CR) |
| rex-1711-f401d65-delta | A | C, C, A | CR, CR, CR | none to catch | none to catch | 0 | 3 | **Yes** (C to CR) |
| rex-1769-03077369-delta | A | A, A, A | A, A, A | none to catch | none to catch | 0 | 0 | No |

Flip count: 3 of 13 (rex-773, rex-1683, rex-1711). Each is a new false alarm on an entry whose key is APPROVED.

### Cause of the flips

The new prompt adds a rule. A count or settings claim that Rex cannot check must become a finding, not only an "Unverified" note. The rule makes it a kind 3 finding when the claim is in a durable record.

- rex-1683: all 3 new runs block on a claim in AgDR-0232 (the CEO approved the wider carry-over) with no source the reviewer can see. The baseline runs approve.
- rex-1711: all 3 new runs block on a new provenance claim (the carried evidence was observed at commit `400db9b4`) that the supplied material does not show. The baseline runs approve or comment.
- rex-773: the new runs block on a comment that states a mechanism the test does not show, and on an unchecked cross-repo base. The baseline runs mostly give COMMENT on the same facts.

In each case the cause is the unverifiable-claim rule, working with an eval that gives Rex no tools and no linked issue. This cause comes from reading the review text, not from a controlled test.

### Other results

- Both prompts give CHANGES REQUESTED on rex-686, rex-677, rex-787 and rex-1289, whose key is APPROVED. This is not a flip. The cause is present in the baseline. The eval hides the PR body and the ticket, and the sanitizer truncates some comments, so Rex blocks on missing evidence.
- Both prompts miss rex-767 D1, rex-748 D1 and D2, and rex-1289 D1 in 3 of 3 runs.
- The blind-spot gains hold: rex-792 D1 goes from 2 of 3 to 3 of 3. rex-770 D1 and D2 stay at 3 of 3. For rex-770 D2, runs k2 and k3 of the new prompt name the mock only in the required fix and the Testing check, not as a numbered blocking issue.
- The FA counts come from reading the blocking findings of each run, including findings marked "conditionally blocking".

### k=8 follow-ups (not run)

Entries that need them: the 3 flips (rex-773, rex-1683, rex-1711). rex-792 also has a mixed baseline (CR, CR, C).
k=8 on both prompts needs 5 more baseline runs and 5 more new-prompt runs per entry, because 3 runs per prompt exist.
That is 30 runs for the 3 flips, or 40 runs with rex-792. Ask the CEO before this spend.
Later, only rex-773 was run at k=8. See the section "rex-773 at k=8".

Runs: 36 new baseline runs plus 39 new-prompt runs, 75 in total. Tokens: 2,979,717 (1,394,396 baseline plus 1,585,321 new-prompt, from CLI JSON usage).

## No-flip re-run (prompt a7b3)

Prompt: `a7b38bd17fe3`. It is the `1ac8` prompt without the sentence that made an unverifiable count or settings claim a blocking finding. An unverifiable claim is an "Unverified" note again.
Protocol: the same as the C4 section. k=3 on four entries. Baselines are the existing v_2656 runs.
Pass condition: no flip on rex-773, rex-1683 and rex-1711 against the v_2656 majority, and rex-1620 D2 caught 2 of 3 or better.

| Entry | Baseline v_2656 | `1ac8` | `a7b3` | Flip with `a7b3` |
|---|---|---|---|---|
| rex-773-ca3a9400 | C, C, CR (majority C) | CR, CR, CR | CR, CR, CR | **Yes** |
| rex-1683-f85a154-delta | A, A, A | CR, CR, CR | A, A, A | No |
| rex-1711-f401d65-delta | C, C, A (majority C) | CR, CR, CR | A, A, A | **Yes** (C to A, toward the key) |
| rex-1620-6229f1c-delta | CR (6 runs) | CR, CR, CR | CR, CR, CR | No |

rex-1620 D2 (the Bedrock setting is missing): `a7b3` catches it 1 of 3 (k1 as a numbered finding; k2 does not name it; k3 lists it only as Unverified). `1ac8` caught it 2 of 3. The baseline caught it 0 of 6.

Result: **FAIL**. Three parts of the pass condition fail. The CEO accepted the result ([#1798 comment](https://github.com/me2resh/apexyard/issues/1798#issuecomment-6279094760)).

- rex-773 still flips. The blocking findings are the cross-repository base order, the wrong mechanism in a code comment, and the wider raw-command haystack. They do not come from the removed sentence. The baseline raised the same points as suggestions or as a COMMENT.
- rex-1711 changes from a COMMENT majority to APPROVED in all 3 runs. This moves toward the frozen key, which is APPROVED.
- rex-1620 D2 falls from 2 of 3 to 1 of 3. The removed sentence helped the D2 catch. rex-1620 D1 stays at 0 of 3.

rex-1683 and rex-1711 are APPROVED in all runs. This confirms that the removed sentence caused the CHANGES REQUESTED verdicts on both.
The other 10 entries were not re-run with `a7b3`. No more runs were made.
Runs: 12. Tokens: 496,109 (from CLI JSON usage).

## rex-773 at k=8

Prompts: baseline `2656e3532425`; new `a7b38bd17fe3`. Eight runs each: the 3 earlier runs plus 5 new runs per prompt.
Verdicts are from reading each review. A is APPROVED, C is COMMENT, CR is CHANGES REQUESTED.

| Prompt | A | C | CR | Majority |
|---|---|---|---|---|
| Baseline `2656` | 0 | 6 | 2 | C |
| New `a7b3` | 0 | 1 | 7 | CR |

Result: the majority verdict flips from C to CR. The difference is beyond baseline variance, but only just: the baseline gives CR in 2 of 8 runs, `a7b3` in 7 of 8, and a two-sided Fisher exact test gives p of about 0.04.
The `a7b3` blocking findings are the same points the baseline gives as suggestions or as a COMMENT: the wider raw-command haystack, the base-ref order for a cross-repository PR, and a wrong cause in the bug 1 comment. They do not come from the unverifiable-claim sentence, which `a7b3` removes.
The entry has no frozen defect, and its key is APPROVED, so the CR verdicts are false alarms by the strict rule. This is the accepted flip on a borderline entry.
Runs: 10. Tokens: 366,471 (from CLI JSON usage).

## Cost totals

Tokens are input, cache creation, cache read and output tokens from the CLI JSON usage blocks.

| Part | Runs | Tokens |
|---|---|---|
| Targeted eval (rex-1765 and rex-1620) | 9 | 519,287 |
| C4 baseline runs (`2656`) | 36 | 1,394,396 |
| C4 new-prompt runs (`1ac8`) | 39 | 1,585,321 |
| No-flip re-run (`a7b3`) | 12 | 496,109 |
| rex-773 at k=8 (`2656` and `a7b3`) | 10 | 366,471 |
| **Total for #1798** | **106** | **4,361,584** |

The #1798 total counts only runs made for this ticket. It does not count the earlier #1773 runs that serve as baseline run 1 of three entries.
The 30 earlier #1773 runs (5 delta entries, 6 phases each) used 1,382,201 tokens.
With them, the combined total is 136 runs and 5,743,785 tokens.

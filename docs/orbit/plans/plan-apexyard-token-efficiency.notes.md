# Notes for plan-apexyard-token-efficiency (current: revision 5)

These notes sit beside the Plan record because the ORBIT v0.1 Plan schema has no fields for constraints, decisions, dependencies or evidence. The Plan record stays valid ORBIT.

## Where the plan comes from

A token-cost debug on 2026-10-10 measured one 10-day session (5,762 API turns, 18 compactions), 386 subagent transcripts and 65 merged PRs, then re-measured each finding under two adversarial lenses. The synthesis is the evidence for every number in the Plan intent. The main findings:

- 78% of spend is the main loop, and 83.6% of that is cache re-reads of a context that averaged 490k tokens per turn. Context size is the largest lever, so it has its own outcome (o2).
- About half of what the main loop re-reads is framework text: skill bodies (25%, of which `/approve-merge` alone 21.5%), skill re-injection after compaction (10%), subagent reports (6%), CLAUDE.md plus the memory index (5%), hook banners (2.4%).
- Every Rex spawn starts at 49k tokens of prompt before it reads the diff: 53% of a review's context and 60% of its cache reads.
- 29% of Rex rounds add no information. The largest class is a round after a base-branch refresh with an unchanged patch (31 rounds in the session), not wording blocks.
- 469 CI-wait turns in 195 of the 350 reviewer runs cost 5.5 hours and 2.6M uncached tokens; 27 of 30 waits of 5 minutes or more expired the prompt cache.

Counting rule for ac6-3: the preamble is a `## Writing rule` heading, and the inline ops-root block is a walk-up that contains the test `$r/.apexyard-fork` (18 skills). Six more skills name the marker in prose or write the marker file; they are not repeats.

The five most-invoked skills in the baseline (ac6-2): `/approve-merge` 209, `/approve-design` 18, `/code-review` 15, `/task` 12, `/start-ticket` 4.

## Constraints

- **C1. The merge gates keep their fail-closed defaults and exit codes.** `block-unreviewed-merge.sh` and `block-merge-on-red-ci.sh` are not edited by this plan; a slice may add tests beside them. A change to what `rex_approval_carries_over` accepts (ac3-2, ac3-3) is an amendment to AgDR-0178 and ships with a paired adversarial bypass test. No slice adds a wrapper around `tracker_pr_merge`, `gh pr merge` or `glab mr merge`: four wrapper shapes were tested and each bypassed both gates.
- **C2. Reviewers stay on Opus** (AgDR-0050, AgDR-0074; `block-agent-routing-drift.sh` pins the model). A lower reasoning effort is allowed only for a delta re-review with a prior marker, through a separate agent file (ac5-3).
- **C3. Measure before and after.** Each slice names the o1 metric it moves and records both numbers in its PR.
- **C4. Zero verdict flips.** A change to a reviewer prompt ships only after k repeated `/eval-agents` runs show no per-entry verdict flip beyond the baseline variance. The corpus grows before the prompt shrinks: a Tariq corpus and at least five Rex delta entries exist before ac5-2 and ac5-3.
- **C5. Prose moves, it is not deleted.** Rationale, history and anti-pattern text removed from an execution path goes under `docs/` behind a one-line pointer, because adopters read it. A docs path that a prompt file names is part of the prompt layer and is reviewed in Full (ac7-1).
- **C6. One slice, one ticket, one PR.** Each outcome has one open slice at a time. A spike may come before the build slice (Revision 3). A fault found inside a slice is a step in that slice.
- **C7. The CEO marker is written only by the inline step 5 of the human-invoked `/approve-merge`.** No script writes `approved_by=user` (ac6-1).

## Decisions

- **CI sequencing (2026-10-10):** the orchestrator waits for green CI without model turns (a Monitor), then spawns Rex. The rule "do not approve while CI is pending" in `code-reviewer.md` stays as written; lines that tell a reviewer to wait are edited (ac4-2). The alternative, an APPROVED verdict conditional on green CI, was not chosen. This applies to the Claude Code harness; Codex and Cursor adapters are covered by plan-apexyard-harness-golden-path o2 and o3.
- **Relation to plan-apexyard-harness-golden-path o4 (2026-10-10):** that plan stays at revision 3. Its o4 slice (`slice-harness-o4-review-agent-token-trim`) runs after o1 and measures with the o1 script (owner decision, 2026-10-11). It owns `omitClaudeMd` and the floor block for Rex and Hakim, the Rex prompt trim, the per-review baseline and the Hakim corpus. This plan's o5 is the increment: the other five review and audit agents, the Hakim and Tariq prompt trims and the lower effort on delta re-reviews. o1 builds the one measurement script with the per-review, session and forge views. Build agents keep CLAUDE.md and the memory index, because their lessons (for example, no non-ASCII in AWS strings) live there and no check would detect the loss.
- **Tier by script (o7)** follows AgDR-0116 Option 4: depth changes inside the review, the merge gate is untouched, and the tier is computed by a script in the spawn path (`auto-code-review.sh` and `/code-review`). An AgDR-0116 evolution entry records it. The lean procedure runs on Opus; a smaller model was considered and rejected.
- **Targets:** ac3-4 counts pure-refresh rounds against refresh events, not rounds per PR, so that it cannot be met by blocking less. ac7-5 is a percentage against the o1 baseline, because an absolute number for a trimmed Opus prompt is not known yet.

## Naqid's challenge (2026-10-10)

Verdict: proceed-with-changes. Applied (Naqid's ten numbered changes, listed by part): step 5 of `/approve-merge` stays inline and a test proves the script has no `approved_by` (ac6-1); C1 restated and the carry-over changes tied to AgDR-0178; the docs-only advisory carry-over dropped, because 3 of 11 wording rewrites added errors; the o7 rail moved out of the merge gate; docs paths named by prompts are Full; a Tariq corpus and five delta entries precede the prompt cuts; `omitClaudeMd` limited to review and audit agents; the reviewer wait lines named; ac3-4 restated; the banner edit merged into o4 and the compact line into o6; context size given its own outcome with a spike; the order starts with the harness o4 slice (superseded on 2026-10-11: o1 runs first; see "Order").

## Prompt-cache TTL (2026-10-10)

Facts, verified in Claude Code CLI 2.1.296:

- The main conversation (`promptCacheTtl`) is 1 hour automatically on a subscription within its usage limits, and 5 minutes on an API key, Bedrock, Vertex or Foundry. The setting text limits the automatic 1 hour to a subscription within its limits. Without a setting or `CLAUDE_CODE_PROMPT_CACHE_TTL`, Bedrock selects a 1-hour TTL only with `ENABLE_PROMPT_CACHING_1H_BEDROCK` or `ENABLE_PROMPT_CACHING_1H`. Either flag also moves subagent requests to 1 hour. An explicit `promptCacheTtl` of "1h" changes only the main conversation. Whether each provider accepts a 1-hour TTL is not verified here.
- Subagents, workflows, background and helper requests (`subagentPromptCacheTtl`) default to 5 minutes on every plan. An agent file can set `experimental.cacheTtl`; "1h" there is ignored in overage. An explicit setting or environment variable takes precedence and is not overage-gated.
- 1-hour cache writes bill at a higher rate. On the API, a 1-hour write costs 2x base input, a 5-minute write 1.25x, and a read 0.1x.
- Usage records carry `cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`, so the TTL of each request is measurable from the transcript.

Measured on the subagent runs of the baseline session, counting an expiry only after a pause of at least 5 minutes:

- 55 cache expiries (median pause 10 minutes) re-wrote 4.76M tokens: 13.0% of 36.5M cache writes. Two full cache losses after short pauses are excluded.
- Causes: 14 reviewer resumes for a delta (7 Rex, 4 Hakim, 3 Tariq; contexts 55k to 180k), 6 "CI is now green" messages to reviewers, 4 build-agent resumes, and 31 other pauses, mostly CI waits inside reviewers and long test or poll loops. o4 removes the CI waits and the CI-green messages.
- At API prices, a 1-hour subagent TTL pays off only when re-writes exceed 39.5% of writes. Naqid's re-measurement adds about 4.0M tokens of shared-prompt rewrites at new spawns, which puts re-writes at 22 to 25% (Rex about 30%). Below the line either way: a 1-hour subagent TTL would add roughly 10M to 18M input-equivalents per session at API prices.
- For the main loop on a 5-minute TTL, re-writes would be about 90% of its writes (Naqid's estimate), because the orchestrator waits for CI under o4.

Decisions:

- The framework does not ship a 1-hour subagent TTL. o4 removes the CI waits and the CI-green messages, and ac7-6 removes the review-delta rebuilds, at no extra write cost.
- ac7-6 resumes a reviewer when its hand-back is under 5 minutes old or its context is under 80k tokens: below 80k, a rebuild costs about the same as a fresh spawn at 49k and keeps the reviewer's memory. Above it, a fresh reviewer is cheaper. Its brief lists each earlier blocking finding and the old..new commit range, and it re-checks each finding before it approves, so a fresh delta cannot skip a finding. It uses the full-effort Rex: the lower-effort agent of ac5-3 needs a prior approval marker (C2), and a delta after a blocking finding has none. The delta corpus entries give the zero-flip check.
- o4 depends on a warm main cache while the orchestrator waits for CI. A subscription within its limits has it by default. Other adopters set `promptCacheTtl` to 1h where their provider supports it (ac4-5).
- Owner trial: `subagentPromptCacheTtl` "1h" in the owner's user settings from 2026-10-10 to 2026-10-17, because subscription accounting for 1-hour writes is not public. It took effect in the running session. Keep it only if weekly usage does not rise against the week before. The o1 script reads the TTL of each request and reports 1-hour runs apart, so the trial does not hide the effect of ac7-6 or o4.

## Order

o1 first, because every later change and the harness o4 slice measure with its script. The owner chose this on 2026-10-11, because the reverse order stalled o1. Then the harness o4 slice. Then o2 (the spike) and o3. o4 runs in parallel with o1: its before numbers are in the baseline, and the o1 script counts the after numbers (owner decision, 2026-10-11). o8 is independent of the others. Then o5, o6, o7. o7 lands after o5 and after the harness o4 trim, because the Lean procedure is measured against the trimmed Rex prompt. Reviewer prompt edits are batched: o4 edits one line each in two agent files; o5 and o7 each run one eval cycle.

## Dependencies

- `slice-harness-o4-review-agent-token-trim` (plan-apexyard-harness-golden-path r3).
- AgDR-0116 (ceremony tiers; Option 4 extended with a scripted tier), AgDR-0172 (two-round cap), AgDR-0178 (`rex_approval_carries_over`, #1437, #1456), AgDR-0104 (decide on exit codes and tree equality, never on parsed diff text), AgDR-0044 (skill token-efficiency waves), AgDR-0050 and AgDR-0074 (reviewers on Opus).
- Harness assumptions to verify in the first slices: `omitClaudeMd` exists for custom agents (CLI 2.1.271 and later); that it also drops the memory index was measured on Explore spawns only, so the harness o4 baseline confirms it for Rex; the per-agent reasoning effort field is undocumented, so ac5-3 starts with a spike; the Monitor wait exists in Claude Code; the main-loop cache stays warm during a CI wait only with a 1-hour main TTL (see "Prompt-cache TTL"; ac4-4 reports rebuilds to check this).

## What stays as is

- The delta re-review after a blocking fix: in 3 of 11 wording fixes the rewrite introduced a new wrong statement, and one delta on a commit described as advisory found a new blocking bug.
- Hakim full scope on hook PRs, including the command-injection section: HIGH findings on 2 of 8 hook-only PRs (#1425, #1524).
- Rex's `gh issue view --comments` on every linked issue: acceptance criteria were amended in comments on #1576 and #1458.
- Rex's round-up of prompt-layer Markdown to Full (#1463).
- Blocking on a misstated count or evidence statement.
- The CEO per-PR nod through a human-typed `/approve-merge`.

## Upstream gaps

- me2resh/orbit-spec#21: one Plan revision per record root; superseded revisions go to `docs/orbit/history/`.
- The Plan schema has no field for a criterion's proof, so each statement ends with a short "Shown by:" clause (me2resh/apexyard#1618 proposes the rule).
- 2026-10-19, owner-approved: Skill-body dedupe: https://github.com/anthropics/claude-code/issues/103425 (new issue)
- 2026-10-19, owner-approved: Fork from a compacted parent, or with a context budget: comment https://github.com/anthropics/claude-code/issues/88841#issuecomment-6265152676
- 2026-10-19, owner-approved: Names-only re-injection after compaction: comment https://github.com/anthropics/claude-code/issues/82144#issuecomment-6265151741
- 2026-10-19, owner-approved: No skill listing for agents without the Skill tool: https://github.com/anthropics/claude-code/issues/103426 (new issue)

## Revision 2 (2026-10-11)

- Adds o8-records-light for AgDR-0225: one linted records PR per planning cycle, a reconciliation only when a status changes, and an /orbit status view. Records PRs keep a reduced-scope Rex review.
- Naqid challenged AgDR-0225 twice. The first challenge dropped a records-only gate exemption, because a check status can be spoofed and Plan history files fall outside any records allowlist.
- Naqid challenged the r2 cycle. Applied: the o4 hook detects review agents from hook input and fails open; the reviewer-text lines move to the harness o4 eval cycle (C4); ac4-5 names pr-workflow.md; ac8-4 builds on orbit progress; ac8-5 counts exception PRs apart and targets 1 round; the o1 slice gains a records-PR classifier and stops counting the one allowed CI check as a wait.
- The o1 slice now points at the revision 2 reconciliation. In o1 to o7, only the ac4-5 statement changed: it names pr-workflow.md.
- Rex on PR #1622: the o4 hook uses the active-reviewer marker only for a subagent with no type, because the marker covers the whole session. The orchestrator is never blocked.
- Correction to the message of commit 3bf5e52 (PR #1620): the wrong range came from a faulty first parse, not from the four most common sizes. In a correct parse the most common sizes are 3,925 to 3,930 bytes.

## Cycle 2026-10-19 (revision 5, dev cee2d239)

- **Reconciliation.** `reconciliation-plan-apexyard-token-efficiency-20261019T062054Z` re-checks every criterion that was not achieved. Two statuses change: ac3-2 and ac5-2.
- **Carried evidence.** The 2026-10-13 records carried the o3 and o5 statuses from 400db9b. They did not assess #1678 or #1683.
- **CEO decisions (2026-10-19).**
  - Cut one slice this cycle: `slice-token-o7-depth-by-tier`. It is one ticket and one PR with a step checklist.
  - After the challenge, the CEO narrowed the slice to ac7-1, ac7-4 and ac7-6. ac7-2, ac7-3 and ac7-5 stay not-verified for a later slice.
  - In that slice, the Rex delta corpus entries come first, because C4 needs them.
  - `slice-token-o2-compaction-build` and `slice-token-o5-effort-spike` stay unchanged. They get their handoff after this records PR merges. They are not withdrawn.
- **Reconciliation challenge decisions (2026-10-19).**
  - ac3-2 stays partially-verified. #1683 checks tree equality at each step of a chain of up to 10 base merges. A git range-diff check is redundant on merge chains. The next plan revision rewords ac3-2 to per-step tree equality.
  - ac5-2 stays partially-verified. Hakim is 22,272 bytes. The Tariq marker text is not one line. #1685 edited Tariq after its zero-flip eval.
  - The figures in ac2-2 and ac2-3 now follow docs/perf/token-cost-baseline-2026-10-10.md. This closes the Figure mismatch (2026-10-12) note.

## Revision 5 (2026-10-13)

- **Owner decision.** A slice PR proposes the next slice, so the next slice record is ready when the PR merges. The owner still chooses each slice. New outcome o10 with ac10-1 to ac10-6.
- **Naqid (2026-10-13): proceed with changes.** All points are applied:
  - Two concurrent slice PRs can propose the same next slice: ac10-5 fails when dev already has a slice record with no ticket for that outcome.
  - The ticket guard reads the default branch, but slice PRs merge to dev: ac10-3 checks the record on the branch the PR merged into.
  - A branch update changes basedOn: ac10-2 needs no new confirmation for a basedOn change, only for a scope change.
  - A no at handoff left a record with no ticket: ac10-6 marks it withdrawn.
  - /approve-merge is near its 14,000-byte cap (ac6-1): it prints one Next line only, and /orbit handoff does the work.
  - Proof goes in the ## Proof section, because the lint warns on proof inside a criterion.
- **Order.** This revision merged after #1714, because the #1714 Reconciliation used revision 4.
- **Owner waiver not needed.** o10 is a new outcome, so its slice is the only open o10 slice (C6).
- **History.** Revision 4, its two Reconciliations and the delivered o8 progress slice (#1714) move to docs/orbit/history/. The other slices point to the revision 5 Reconciliation only because the validator requires it.

## Revision 4 (2026-10-13)

- **Problem.** The ORBIT pane reads only Reconciliations merged on dev. A slice PR merges, but its progress waits days for a separate records PR.
- **Owner decision.** A slice build PR carries its own Reconciliation, so progress shows when the PR merges. CI runs the records lint. Rex reviews the Reconciliation as a normal file in the diff. A missing Reconciliation warns and never blocks. A merge alone moves no status.
- **Changes.** The o8 title covers slice PRs. New criteria ac8-6 to ac8-10.
- **Naqid (2026-10-13): proceed with changes.** All points are applied:
  - Lost statuses from concurrent slice PRs: ac8-9 fails a change to a criterion outside the slice's contributesTo list.
  - Snapshot commit after a squash merge: ac8-10 records the dev merge-base and the PR number.
  - Lint scope on feature branches and in CI: the lint gets the initiative from the slice record, not from the branch name.
  - Conflict with AgDR-0225 option I and ac8-3: an AgDR amends option I. ac8-8 warns only when a status changed.
  - ac8-7 needs a fault a lint can judge: raised status evidence must name a path in the PR diff.
- **ac8-5.** Slice PRs that carry a Reconciliation do not count as records PRs.
- **Other initiative.** Build with ORBIT ac2-3 says that Rex reads no ORBIT record. A separate records PR amends it to "outside the PR diff". The lint allows one initiative per records PR.
- **Owner waiver (2026-10-13).** `slice-token-o8-progress-at-merge` may stay open next to the first o8 slice (C6). The first slice holds only ac8-5, a measurement with no build work.
- **History.** Revision 3, its three Reconciliations and the delivered o2 spike and o6 slices move to docs/orbit/history/. The other slices point to the revision 4 Reconciliation only because the validator requires it. Their text is unchanged.

## Proof

Revision 4 keeps proof out of the new criterion statements. The older criteria keep their "Shown by" text until a later revision.

- ac8-6: the skill text and the next slice PR.
- ac8-7: a lint test on a faulty fixture.
- ac8-8: the workflow and a test.
- ac8-9: a test with two concurrent slice PRs.
- ac8-10: the skill text and a test.
- ac10-1: the skill text and the next slice PR.
- ac10-2: the skill text and a slice PR review thread.
- ac10-3: the skill text and a handoff test on a dev-only record.
- ac10-4: the skill text and a test with every outcome achieved.
- ac10-5: a lint test with two concurrent proposals.
- ac10-6: the skill text and a test of a withdrawn slice.

## Interview

- 2026-10-13, q1-outcome: (revision 4) The ORBIT pane shows a slice's new statuses when its build PR merges, with no second records PR.
- 2026-10-13, q2-intent: (revision 4) Unchanged.
- 2026-10-13, q3-outcomes: (revision 4) Amend the o8 title to cover slice PRs. Other outcomes stay.
- 2026-10-13, q4-acceptance: (revision 4) Add ac8-6 to ac8-8 as drafted, then ac8-9 and ac8-10 after the Naqid challenge.
- 2026-10-13, q5-constraints: (revision 4) A missing Reconciliation warns and never blocks. A merge alone moves no status. CI lint plus Rex on the diff check the Reconciliation.
- 2026-10-13, q6-save: (revision 4) Save revision 4 as revised after the Naqid challenge.
- 2026-10-13, q1-outcome: (revision 5) When a slice PR merges, the next slice record already exists on dev. Filing its ticket takes one confirmation.
- 2026-10-13, q2-intent: (revision 5) Unchanged.
- 2026-10-13, q3-outcomes: (revision 5) Add a new outcome o10, so o8 stays about records and o10 needs no C6 waiver.
- 2026-10-13, q4-acceptance: (revision 5) Add ac10-1 to ac10-5 as drafted. After the Naqid challenge, amend ac10-2, ac10-3 and ac10-5, and add ac10-6.
- 2026-10-13, q5-constraints: (revision 5) The owner confirms the scope in the PR review. The ticket is filed only after merge and a yes. With no outcome left, propose nothing. Naqid challenges each proposal.
- 2026-10-13, q6-save: (revision 5) Save as revised after the Naqid challenge.

## Revision 3 (2026-10-11)

- o1 (#1633), o4 (#1634) and o8 (#1630) merged. The reconciliation records their statuses with file and test evidence.
- **Baseline correction (ac4-4).** The new figure is 420 CI-wait turns in 185 of 388 reviewer runs. The old synthesis was the faulty side: it counted every CI check and 10 non-CI sleeps. The run count moved from 350 to 388, because the script covers all of 2026-10-10. The gap is 10.4%, over the o1 gate of 5%, because the old number was wrong (PR #1633).
- **Baseline correction (ac7-6).** The o1 script counts 21 resume rebuilds in 388 runs. Without CI-green messages it counts 15, which is 3.87 per 100. The old figure was 4.0 per 100 in 350 runs.
- **o9 (reviews run in parallel).** It is a new outcome, not an o7 criterion: o7 is about review depth and o9 is about concurrency. Review agents are found by agent type, as the o4 hook does, so the orchestrator and build agents are never blocked. Owner decision 2026-10-11: o9 moves ahead of the other token-plan work, because the session-wide review lock held up two build commits and five orbit-spec builds that day. The harness o1 slice (#1623) merges first, because its PR was ready first. o9 rebases on it, since both edit dispatch-bash.sh.
- **Parked: ac3-3.** A reopened PR has no Rex marker under its new number (block-unreviewed-merge.sh lines 459-462). Carry-over would need a merge-gate edit, which breaks C1, or an agent-written marker, which is forbidden.
- **Parked: ac3-2.** It waits until a count shows how often chained refreshes happen. **Update (2026-10-19):** #1683 added chain carry-over, so ac3-2 is partially-verified. See the 2026-10-19 cycle.
- **C6 amended.** One open slice per outcome; a spike may come before the build slice. The o2 spike covers ac2-1, and a later o2 build slice covers ac2-2 to ac2-4.
- **Delivered slices.** The o1, o4 and o8 slices are re-pointed to this reconciliation only because the validator requires their reconciliation in docs/orbit/reconciliations/. Their text is unchanged.
- This cycle cuts the o2 spike slice (ac2-1) and the o3 slice (ac3-1 and ac3-4).
- **o6 slice (2026-10-11).** `slice-token-o6-skill-bodies-lean` covers ac6-1 to ac6-5 in one PR. Owner decision 2026-10-11: cut it now, after o9 merged (#1651). o5 waits for the harness o4 PR (#1652), and o7 waits for o5. Naqid returned proceed-with-changes. The record has all seven changes. They are a fail-closed script contract, a strategy allow-list, a no-marker-write test, the ops-root bootstrap kept inline, repointed tests, the fixed five-skill list, and a Full Rex review plus a Hakim review.
- **Reconciliation 2026-10-11T22:32Z (dev 9b25c83).** It follows the merges of #1651 (o9), #1646 (o2 spike) and #1652 (harness o4). ac2-1, ac3-1, ac4-2 and ac8-2 are achieved. ac5-1 and ac9-1 are partially-verified.
- **o5 slice (2026-10-11).** `slice-token-o5-review-agents-lean` covers ac5-1 and ac5-2. The owner chose this cut; ac5-3 gets a later spike slice. Naqid returned proceed-with-changes, and the record has all seven changes.
- **Owner waiver (2026-10-11).** In o5, Hakim gets two eval cycles instead of one. The trim runs first and omitClaudeMd second, so a flip traces to one change. Hakim missed a HIGH defect with omitClaudeMd in #1652, and the cause is not known.
- **o5 effort spike (2026-10-12).** `slice-token-o5-effort-spike` covers part of ac5-3. Naqid returned proceed-with-changes, and the record has all 14 changes.
- **Owner waiver (2026-10-12).** The o5 effort spike may stay open next to the o5 slice #1662, as a second open o5 slice (C6). It has a payoff gate. Step 0 counts delta rounds and their thinking-plus-output share. The spike stops if the best case is below the 20% noise floor from #1652.
- **o2 build slice (2026-10-12).** `slice-token-o2-compaction-build` covers ac2-2 to ac2-4. Naqid returned proceed-with-changes, and the record has all 15 changes.
- **Owner decision (2026-10-12).** The o2 build uses one draft PR. The ac2-3 and ac2-4 commits come first, and the ac2-2 measurement commit comes last. ac2-2 is time-boxed to 7 days after o6 (#1663) merges. With no valid session by then, the PR merges and ac2-2 stays not-verified. The window floor is 300,000.
- **Figure mismatch (2026-10-12).** The reconciliation's p90 853k, fork 281k and 17.8M figures differ from docs/perf/token-cost-baseline-2026-10-10.md. The baseline file governs. The next reconciliation corrects them.

## Checks

Each check that changes no status adds one line here: date, commit, result (AgDR-0225).

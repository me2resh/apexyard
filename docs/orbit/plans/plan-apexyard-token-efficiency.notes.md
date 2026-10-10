# Notes for plan-apexyard-token-efficiency (current: revision 1)

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
- **C6. One slice, one ticket, one PR.** Each outcome has one slice. A fault found inside a slice is a step in that slice.
- **C7. The CEO marker is written only by the inline step 5 of the human-invoked `/approve-merge`.** No script writes `approved_by=user` (ac6-1).

## Decisions

- **CI sequencing (2026-10-10):** the orchestrator waits for green CI without model turns (a Monitor), then spawns Rex. The rule "do not approve while CI is pending" in `code-reviewer.md` stays as written; lines that tell a reviewer to wait are edited (ac4-2). The alternative, an APPROVED verdict conditional on green CI, was not chosen. This applies to the Claude Code harness; Codex and Cursor adapters are covered by plan-apexyard-harness-golden-path o2 and o3.
- **Relation to plan-apexyard-harness-golden-path o4 (2026-10-10):** that plan stays at revision 3 and its o4 slice (`slice-harness-o4-review-agent-token-trim`) runs first. It owns `omitClaudeMd` and the floor block for Rex and Hakim, the Rex prompt trim, the per-review token measurement and the Hakim corpus. This plan's o5 is the increment: the other five review and audit agents, the Hakim and Tariq prompt trims and the lower effort on delta re-reviews. o1 reuses the o4 measurement script and adds the session and forge views. Build agents keep CLAUDE.md and the memory index, because their lessons (for example, no non-ASCII in AWS strings) live there and no check would detect the loss.
- **Tier by script (o7)** follows AgDR-0116 Option 4: depth changes inside the review, the merge gate is untouched, and the tier is computed by a script in the spawn path (`auto-code-review.sh` and `/code-review`). An AgDR-0116 evolution entry records it. The lean procedure runs on Opus; a smaller model was considered and rejected.
- **Targets:** ac3-4 counts pure-refresh rounds against refresh events, not rounds per PR, so that it cannot be met by blocking less. ac7-5 is a percentage against the o1 baseline, because an absolute number for a trimmed Opus prompt is not known yet.

## Naqid's challenge (2026-10-10)

Verdict: proceed-with-changes. Applied (Naqid's ten numbered changes, listed by part): step 5 of `/approve-merge` stays inline and a test proves the script has no `approved_by` (ac6-1); C1 restated and the carry-over changes tied to AgDR-0178; the docs-only advisory carry-over dropped, because 3 of 11 wording rewrites added errors; the o7 rail moved out of the merge gate; docs paths named by prompts are Full; a Tariq corpus and five delta entries precede the prompt cuts; `omitClaudeMd` limited to review and audit agents; the reviewer wait lines named; ac3-4 restated; the banner edit merged into o4 and the compact line into o6; context size given its own outcome with a spike; the order starts with the harness o4 slice.

## Prompt-cache TTL (2026-10-10)

Facts, verified in Claude Code CLI 2.1.296:

- The main conversation (`promptCacheTtl`) is 1 hour automatically on a subscription within its usage limits, and 5 minutes on an API key, Bedrock, Vertex or Foundry. The setting text limits the automatic 1 hour to a subscription within its limits. Without a setting, Bedrock selects a 1-hour TTL only with `ENABLE_PROMPT_CACHING_1H_BEDROCK` or `ENABLE_PROMPT_CACHING_1H`. Either flag also moves subagent requests to 1 hour. An explicit `promptCacheTtl` of "1h" changes only the main conversation. Whether each provider accepts a 1-hour TTL is not verified here.
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

The harness o4 slice first, because o1 reuses its measurement script. Then o1. Then o2 (the spike), o3 and o4, which are independent. Then o5, o6, o7. o7 lands after o5 and after the harness o4 trim, because the Lean procedure is measured against the trimmed Rex prompt. Reviewer prompt edits are batched: o4 edits one line each in two agent files; o5 and o7 each run one eval cycle.

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
- Harness requests under ac2-4 are filed with Claude Code, not in this repo; the links go here when they exist.

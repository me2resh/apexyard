---
id: AgDR-0254
timestamp: 2026-10-19T00:00:00Z
agent: tech-lead (Hisham)
model: claude-opus-5-5
session: spike-1775-discard
trigger: user-prompt
status: accepted
category: patterns
---

# AgDR-0254: Reject a lower-effort Rex delta reviewer

> In the context of spike #1775 and ORBIT slice `slice-token-o5-effort-spike`, facing a step 0 payoff gate that failed, I decided not to add a lower-effort Rex delta reviewer, to keep `ac5-3` work on targets that can move cost, accepting that the `effort:` frontmatter key is real but unused here.

## Context

Spike me2resh/apexyard#1775 asked whether a per-agent reasoning effort on Opus could make Rex delta re-reviews cheaper. Step 0 measured the thinking-plus-output share of local `code-reviewer` transcripts with `docs/spike-memos/probes/GH-1775-step0-output-share.py` and `usage_numbers` from `bin/token-cost.py`. In the API usage record, `output_tokens` includes thinking tokens.

| Set | Runs | Output share of uncached tokens | Output share, cost-weighted |
|---|---|---|---|
| All Rex runs | 541 (at the time of the run) | 7.9% | 10.2% |
| Delta-like runs | 261 | 8.4% | 11.1% |
| Delta with explicit prior approval | 4 | 18.1% | 19.6% |

The 261-run delta-like set stands in for the gate's group (delta rounds after a prior Rex approval). The 4-run prior-approval subset is too small to use. Even if lower effort removed all thinking and output, the saving on the delta-like set is 8.4% by tokens and 11.1% cost-weighted. Both sit below the 20% noise floor from the #1652 report. The gate fails.

The CLI schema text names an `effort:` frontmatter key on `.claude/agents/*.md` (Claude Code 2.1.303 binary strings). Allowed values are named levels or an integer. The Agent tool also has a per-spawn `effort` parameter. A live headless session did not run, so this record does not confirm that a transcript shows Opus with the key set.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Add a lean-effort Rex delta agent and route delta re-reviews to it | Uses the real `effort:` key | Best-case saving is below the 20% gate; eval cost with no proven payoff |
| B. Reject the lean-effort delta reviewer; retarget `ac5-3` | Matches the measured ceiling; frees later work for larger levers | Leaves the `effort:` key unused until a revisit |
| C. Continue the spike without the payoff gate | Would gather effect-test data | Spends Rex runs against a known sub-20% ceiling |

## Decision

Chosen: **Option B**, because thinking plus output is 8.4% of a delta-like run and 11.1% cost-weighted, both below the 20% gate.

Revisit only when a later measure shows thinking tokens above 20% of a delta run.

A better target for `ac5-3` is the turn count and the first-turn context of delta runs. The mean delta-like run used 17.1 turns. The delta corpus entries that this spike would have mined move to o7 slice #1773, which already builds the Rex delta corpus.

## Consequences

- No lean-effort agent file. No change to `code-reviewer.md`. No merge-gate hook edit.
- Spike memo: `docs/spike-memos/GH-1775-per-agent-effort.md` (DISCARD).
- Delta corpus work continues under #1773, not under #1775.

## Artifacts

- me2resh/apexyard#1775
- me2resh/apexyard#1779
- `docs/spike-memos/GH-1775-per-agent-effort.md`
- `docs/orbit/slices/slice-token-o5-effort-spike.json`
- CEO decision, 2026-10-19: rejection AgDR plus move of delta corpus entries to #1773

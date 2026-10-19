# Spike memo: Can lower reasoning effort make the Rex delta reviewer cheaper?

> **Disposition: DISCARD (killed at step 0).** The payoff gate failed.
> Thinking plus output tokens are about 8% of a Rex run. The best-case saving is below the 20% noise floor.
> The effort key exists and works as a frontmatter field. The spike stopped before any Rex eval run.

- **Spike ticket**: me2resh/apexyard#1775
- **ORBIT slice**: `slice-token-o5-effort-spike`
- **Acceptance criterion**: part of `ac5-3` of `plan-apexyard-token-efficiency`
- **Date**: 2026-10-19

## Question

Can a per-agent reasoning effort be set on an Opus custom agent?
Does a lower-effort Rex delta reviewer keep its verdicts and use fewer tokens?

## Step 0: payoff gate (the kill criterion that fired)

Method: `docs/spike-memos/probes/GH-1775-step0-output-share.py` reads every `code-reviewer` subagent transcript in the local Claude Code project store.
It uses `usage_numbers` from `bin/token-cost.py`. In the API usage record, `output_tokens` includes thinking tokens.
So "thinking plus output" is `output_tokens`.
It sorts runs by the words in the first prompt. A delta run matches "delta", "re-review", "since last", "prior approval" and similar words.

| Set | Runs | Mean uncached tokens | Mean output tokens | Output share of uncached tokens | Output share, cost-weighted |
|---|---|---|---|---|---|
| All Rex runs | 541 (at the time of the run) | 126,466 | 9,950 | 7.9% | 10.2% |
| Delta-like runs | 261 | 92,127 | 7,731 | 8.4% | 11.1% |
| Delta with explicit prior approval | 4 | 129,928 | 23,540 | 18.1% | 19.6% |

Terms: "uncached tokens" is input plus cache creation plus output, the `total_tokens` rule of the o1 script.
"Cost-weighted" counts output at 5x input, cache creation at 2x (1-hour cache) and cache read at 0.1x. These weights are an assumption, not a price list.
The 261-run delta-like set stands in for the gate's group (delta rounds after a prior Rex approval).

Result: even if lower effort removed all thinking and output (a limit that cannot happen), the saving is 8% to 11%.
The gate needs more than 20%. The gate fails.
The 4-run set is too small to use. Its share is still below 20% by tokens, and just below 20% cost-weighted.
Lower effort can also cut the number of turns. Fewer turns cut cache reads. This second effect is not measured here.
The mean delta-like run uses 17.1 turns. A turn cut is a possible saving, but only a real eval run can show it.

## Step 1: the effort key (facts)

- **Key**: `effort` in the `.claude/agents/*.md` frontmatter. The CLI schema text reads: "Reasoning effort level for this agent. Either a named level or an integer".
- **Allowed values**: the named levels `low`, `medium`, `high`, `xhigh`, `max`, or an integer. A bad value gives the message "has invalid effort ... Valid options: ... or an integer".
- **Source**: strings in the Claude Code 2.1.303 binary. The system prompt of the Agent tool says: "Each agent type's model, reasoning effort, and tools come from its definition (`.claude/agents/*.md` frontmatter or SDK `agents`)".
  The SDK `agents` option has the same field.
- **Minimum CLI version**: not stated in the binary. I did not reach a docs page. The slice cites 2.1.296 as the version with the Agent tool text. This spike ran on 2.1.303.
  I did not test an older version.
- **Per-spawn option**: the Agent tool also has an `effort` parameter. It is ignored for `subagent_type: "fork"`.
  C2 still needs a separate agent file. A hook can read and pin a file. A hook cannot see or pin a per-spawn option.
- **Other controls seen**: the env var `CLAUDE_CODE_EFFORT_LEVEL`, the flag `--effort <level>`, and a session effort setting. They set the session effort, not one agent type.
  A hook receives the active effort in the `CLAUDE_EFFORT` env var.
- **Not tested**: no headless session ran. So I did not confirm that the transcript shows Opus with the key set. That is step 2.

## Routing hooks (read only)

I read `apply-agent-routing.sh` and `block-agent-routing-drift.sh`.
Both act on the `model:` line only. The sync hook rewrites that line. The drift guard compares that line with the framework default.
Neither one reads or removes an `effort:` line, so the key should survive. An unknown agent type is not blocked by name in the parts I read.
No test ran. A build slice must run `test_agent_routing_sync_and_drift.sh` with an `effort:` line added.

## Not done, and why

- Step 2 (headless probe), step 3 (five delta corpus entries), step 4 (eval at k=3 and k=8): stopped by the step 0 kill.
- Token numbers per run before and after: none exist. No Rex run was made. Rex runs spent: zero.
- Verdict flips: not measured.
- The rejection decision is in [AgDR-0254](../agdr/AgDR-0254-reject-lean-effort-rex-delta.md). The eval report was not written because no Rex eval ran.
- The slice says delta corpus entries still ship on a kill. Those entries move to o7 slice #1773, which already builds the Rex delta corpus. They were not mined in this spike.

## Frontmatter diff of the throwaway agent

No throwaway agent file was made. The variant to reproduce, if ever promoted, is the `code-reviewer.md` frontmatter plus one line:

```diff
 model: opus
+effort: low
 omitClaudeMd: true
```

The level `low` is untested. It is a placeholder.

## Recommendation

Discard. A lean-effort Rex delta reviewer has a small ceiling because Rex cost is mostly cache-read and input context, not thinking.
A better target for `ac5-3` is the turn count and the first-turn context of delta runs. Re-open this spike only if a later measure shows thinking tokens above 20% of a delta run.

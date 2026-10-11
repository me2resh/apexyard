# Spike memo: Does the auto-compaction setting bound the context on 1M-context Opus?

> **Disposition: PROMOTE the setting to docs.** The setting exists and bounds the context.
> The recommended value is `autoCompactWindow` of `500000`. This value is an extrapolation that ac2-2 must confirm.

- **Spike ticket**: me2resh/apexyard#1637
- **ORBIT slice**: `slice-token-o2-compaction-spike`
- **Acceptance criterion**: `ac2-1` of `plan-apexyard-token-efficiency`
- **Date**: 2026-10-11

## Question

Does the Claude Code auto-compaction setting bound the context per turn on a 1M-context Opus model?
The 2026-10-10 baseline shows a main-session mean of 489,792 tokens per turn and 18 compactions, 12 of them near the cap.
See [`docs/perf/token-cost-baseline-2026-10-10.md`](../perf/token-cost-baseline-2026-10-10.md).

## Terms

- **Auto-compact window**: the number of tokens at which Claude Code starts to compact a conversation.
- **Context per turn**: the input tokens of one request. This is uncached input plus cache creation plus cache read.
- **Compaction**: Claude Code replaces the conversation with a summary.
- **o1 script**: `bin/token-cost.py`. Its `session` view reports context per turn and compactions.

## The setting

The setting exists. The Claude Code documentation names four ways to set it.

| Way to set it | Name | Allowed values | Default | Minimum CLI version |
|---|---|---|---|---|
| Settings file, every model | `autoCompactWindow` | Whole number of tokens from `100000` to `1000000` | Unset. Claude Code uses a window tuned for the model. | Not stated in the docs. Tested on 2.1.296. |
| Settings file, one model | `modelSettings.<model>.autoCompactWindow` | A token number in the same range, or `"auto"` | Unset | 2.1.288 |
| One launch | `--autocompact <auto\|tokens>` | `auto`, or 100K to 1M with a `k` or `M` suffix | Unset | 2.1.221 |
| Scripts | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | Plain integer only. `500k` reads as `500`. | Unset | Not stated in the docs |

Precedence, highest first: the environment variable, the flag, the per-model entry, the top-level key.
Claude Code caps the value at the model window.
For Opus 4.7 and later, the documented default compaction point is about 967K tokens.
The `/autocompact` command saves the per-model entry in your user settings.

## Setup

- **CLI**: Claude Code 2.1.296. **Model**: `claude-opus-5-5`, 1M window, effort `low`.
- **Task**: the same prompt in every session. The model reads 12 generated text files with the Read tool, one call per turn.
  Each file is about 69 KB. The model then prints the first word of the last line of each file.
- **Isolation**: each session ran with `claude -p` in a throwaway directory.
  The session loaded only a temporary settings file through `--settings`, with `--setting-sources project`.
  The only tool was Read. The sessions had no MCP servers, no skills, no hooks and no network write path.
- **Values**: unset (default), `100000`, `200000`, `300000`, `400000`.
  Default, 100K and 200K ran twice. 300K and 400K ran once.
- **Measure**: the o1 script `session` view on each transcript.
- **Spend cap**: 6 USD per session. Total spend was 36.83 USD.

## Results

| Window | Runs | Mean context per turn | p90 context | Max context | Compactions | Mean context at compaction | Cost per run (USD) | Answers correct |
|---|---|---|---|---|---|---|---|---|
| Default (unset) | 2 | 232,894 and 245,876 | 421,098 and 422,460 | 459,158 and 460,656 | 0 and 0 | none | 4.63 and 4.51 | 12 of 12, twice |
| 400,000 | 1 | 161,153 | 331,585 | 369,693 | 1 | 377,336 | 4.44 | 12 of 12 |
| 300,000 | 1 | 135,250 | 254,136 | 270,169 | 1 | 280,711 | 4.13 | 12 of 12 |
| 200,000 | 2 | 88,960 and 89,540 | 157,072 and 156,884 | 158,170 and 157,091 | 2 and 2 | 171,874 and 166,786 | 4.44 and 4.71 | 12 of 12, twice |
| 100,000 | 2 | 41,739 and 41,653 | 65,358 and 65,272 | 65,689 and 65,557 | 7 and 7 | 71,614 and 71,528 | 4.99 and 4.96 | 12 of 12, twice |

## Run-to-run variance

- At 100K the two means differ by 0.2 percent. At 200K they differ by 0.6 percent.
- The default runs differ by 5.6 percent in the mean. The model changed its read pattern in one default run, which changed the turn count from 25 to 21.
- The compaction count was the same in both runs at 100K and at 200K.
- One default session and one 200K session reported that they broke the one-call-per-turn rule. Their answers stayed correct.
- The step between neighbouring windows is much larger than the variance. The mean falls from about 239,000 at default to about 41,700 at 100K.

## Findings

1. **The setting bounds the context.** The maximum context stayed below the window in every run.
   The maximum was 30,000 to 43,000 tokens below the window at 100K to 400K.
   Claude Code recorded each compaction 19,000 to 33,000 tokens below the window.
   In this task, the maximum context was therefore the window minus a margin of about 30,000 to 43,000 tokens.
2. **The window moves the mean with the cap.** The mean was 0.44 to 0.64 of the maximum in every row. The ratio fell as the window grew.
3. **Cost did not fall.** The cost per run stayed between 4.13 and 4.99 USD for every value.
   One-time cache writes of the file text (about 435,000 to 475,000 tokens) dominate this task.
   Cache-read tokens fell from about 5.0 million at default to about 0.58 million at 100K.
   The 100K window cost about 9 percent more than default, because compaction rebuilds the cache.
   With two runs per value, this cost difference is small and not proven.
4. **No quality loss showed.** All eight sessions gave all 12 answers correctly.
   This task keeps one word per file. It is a weak test of summary quality.

## Limits of this evidence

- **Scale.** The task reached 460,000 tokens at most. The default compaction point of about 967,000 was not reached.
  A full-scale run costs about four times as much per session and was outside the budget.
- **Extrapolation.** The 500,000 recommendation uses the measured rule that the maximum is the window minus 30,000 to 43,000 tokens.
  It also uses the measured ratio of mean to maximum of 0.44 to 0.5 for windows of 300,000 and above.
  No session ran at 500,000.
- **Headless sessions.** The runs used `claude -p`. Interactive sessions were not tested.
- **Small sessions.** The sessions held a bare system prompt. A real session carries a larger fixed base of rules and tool definitions.
- **Quality.** The test did not measure how well a long task survives repeated compaction. A low window raises that risk.

## Recommendation

Set `autoCompactWindow` to `500000` in your user settings (`~/.claude/settings.json`).
Do not set it in a shared project file. A per-model entry from `/autocompact` overrides the top-level key.

Reasons for 500,000:

- The measured rule gives a maximum context of about 460,000 to 470,000 tokens.
- A mean-to-maximum ratio of 0.44 to 0.5 predicts a mean of about 205,000 to 235,000 tokens in this task shape.
- A real session has a larger fixed base, so allow headroom. The ac2-2 target is at most 300,000, from 490,000.
- The baseline session has a ratio of mean to cap of 0.51, which is close to the measured ratio.
- A window below 300,000 gave no cost saving in this spike and compacts often.

Use `--autocompact` for one launch. Use `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in scripts.
Criterion ac2-2 must measure a real session at 500,000 with the o1 script. If the mean stays above 300,000, lower the value in steps of 100,000.

## Kill-criteria outcome

| Kill criterion | Outcome |
|---|---|
| The setting does not exist. | Not met. `autoCompactWindow` exists and works in `claude -p`. |
| Two runs show no difference beyond run-to-run variance. | Not met. The windows differ by far more than the variance. |
| Budget of about 2 hours of agent time and a hard spend cap. | Not met. The spike stayed inside the budget: well under 2 hours and 36.83 USD. |

## Out of scope

This memo does not cover the compact prompt, the 300k target, fork and spawn rules, harness requests, or reviewer and subagent settings.
Those belong to ac2-2, ac2-3 and ac2-4.

## Sources

- Claude Code docs: model configuration, section "Set the auto-compact window".
- Claude Code docs: settings reference, entries `autoCompactWindow` and `modelSettings`.
- Claude Code docs: environment variables and CLI reference.

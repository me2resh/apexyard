# Token cost measurement

`bin/token-cost.py` reports the token and time cost of a Claude Code session.
It is the one measurement script of the token-efficiency plan (me2resh/apexyard#1624, outcome o1).
Each later slice measures with this script and writes no second script.
The dated baseline is in [token-cost-baseline-2026-10-10.md](token-cost-baseline-2026-10-10.md).

## Terms

- **Transcript**: the JSONL file that Claude Code writes for one session.
  It is under `~/.claude/projects/<project>/<session-id>.jsonl`.
- **Subagent transcripts**: the JSONL files under `<session-id>/subagents/`.
  Each file has a `.meta.json` file that names the agent type.
- **Request**: one API call. Claude Code writes one record per content block, so the script joins the records of one message id.
- **Context**: the input tokens of one request: uncached input plus cache creation plus cache read.
- **Total tokens**: uncached input plus cache creation plus output, summed over the requests of a run.
  Cache-read tokens are reported apart.
- **Reviewer run**: one run of Rex (`code-reviewer`), Hakim (`security-reviewer`) or Tariq (`solution-architect`).

## What the script reads and writes

The script reads local files only, plus the GitHub CLI for the forge view.
It prints JSON or Markdown to standard output.
It does not print transcript text, prompts or local paths.
The forge view reads only `me2resh/apexyard`.
Do not commit a transcript, a saved forge file or a per-run JSON file.
Commit only the Markdown report.

Requirements: Python 3.9 or later, `git`, and an authenticated `gh` for the forge view.

## The views

| View | Command | Reports |
|---|---|---|
| Session | `session --transcript <session.jsonl>` | Context per turn (mean, p50, p90, p99, max), context share by category, skill injections, compactions, main-loop cache rebuilds, main-loop cache rebuilds during a CI wait, requests with 1-hour and 5-minute cache writes, wall time |
| Reviewer | `reviewers --subagents <session-dir>/subagents` | Per reviewer and per review: first-turn context, total tokens, cache-read tokens, tool calls, CI-wait turns, long CI waits, cache rebuilds, resume rebuilds, cache TTL, wall time. Other agent types in a separate table |
| Forge | `forge --forge-range A-B` or `--forge-last N` | Rex rounds per PR, hours from open to merge, pure-refresh rounds and refresh events, records PRs |
| Locks | `locks --transcript <session.jsonl> --subagents <session-dir>/subagents` | Tool calls that the reviewer lock blocked, split into blocked commits, blocked pushes and other commands, and per UTC day |
| Report | `report` with any of the options above | All views in one JSON or Markdown document. A transcript or subagents option adds the lock counts |
| Compare | `compare before.json after.json` | The relative change of each metric between two JSON reports |

Use `--since` and `--until` (ISO-8601) to measure one window of a session.
A record without a timestamp takes the timestamp of the record before it.

The session view groups a skill that is not tracked under `.claude/skills/` in this repository as `other`.
Private, premium and harness skills therefore never appear by name.

The reviewer view puts a run in the 1-hour group when any request of the run has a 1-hour cache write.
All other runs are in the 5-minute group.
The session view counts main-loop requests with each TTL.

## Counting rules

These rules are binding (slice `slice-plan-apexyard-token-efficiency-20261011T051806Z`).
The tests in `.claude/hooks/tests/token_cost/` check each rule on fixture transcripts.

- **CI-wait turn**: a reviewer turn whose only tool call polls CI status.
  - A poll is `gh pr checks`, `gh run watch|view|list`, a `gh api` call on check runs, statuses or Actions runs. A `--watch` flag counts only on the checks command.
  - A bare `sleep N` counts as a poll, because a reviewer sleeps only to wait for CI.
  - The first single `gh pr checks` turn of a run does not count.
  - The first checks call of a run uses up this exemption in any turn shape. After a check in a turn with other tool calls, a later single check counts.
  - A turn with a poll and another tool call does not count.
- **Cache rebuild**: a request whose cache-creation tokens exceed half its input tokens.
  - The first request of a run builds the cache. The script does not count it as a rebuild.
  - The session view reports the first request after a compaction apart, because a compaction always rebuilds.
- **Resume rebuild**: a cache rebuild on the first request after a hand-back.
  - A hand-back is a request with no tool call or with a `SubagentHandback` call.
  - The per-100-runs rate excludes a resume after a "CI is green" message, because o4 removes those messages.
- **Long CI wait**: a CI-wait turn whose tool result comes 300 seconds or more after the call.
  The report also counts each long wait that the next request follows with a cache rebuild.
- **Main-loop cache rebuild during a CI wait**: a main-loop CI-wait turn (no first-check exemption) that the next request follows with a cache rebuild.
- **Rex round**: one Rex verdict on one head commit.
  - Rex posts a review or a comment with a `## Code Review` heading. Hakim uses `## Security Review` and Tariq uses `## Design Review`.
  - A comment takes the last PR commit committed before the comment.
  - The same verdict on the same head again is not a new round. A COMMENT and then an APPROVED on one head are two rounds.
- **Pure-refresh round**: a Rex round on a head that differs from the approved head only by a base merge.
  - A base merge is a merge commit with a parent outside the PR commits.
  - The approved head is the head of the last Rex APPROVED round.
- **Refresh event**: a base-merge commit after a Rex approval, with no other commit between that approval and the merge.
  Each Rex approval starts its own count. The script counts pure-refresh rounds after each approval too.
- **Records PR**: every file is under `docs/orbit/`, with or without one `docs/agdr/AgDR-*.md` file.

## Count blocked commits and pushes

The `locks` view counts hook blocks that the reviewer mutation lock caused (me2resh/apexyard#1649).
A block is a failed tool result that starts with `PreToolUse:` and `hook error`, and contains the lock message `BLOCKED: review-class agent`.
Text that only quotes the message, for example an issue body, does not count.
The script looks up the command of the call by its tool-use id and sorts the block into commit, push or other.

Rule for combining counts across sessions:

1. Name each block by its tool-use id.
2. Read every main-loop transcript and every subagent transcript of the period.
3. Count each tool-use id once. A resumed session copies earlier records into a new file.
4. Add the counts of all transcripts. Report `commit_or_push` as the headline number.
5. Group by the UTC date of the result when the period spans several days.

Run the script with several `--transcript` and `--subagents` options to combine sessions in one call.
The script counts blocks that reach the transcript. It cannot count a block that a hook logs only to a file.

## Record the before and after numbers of a slice

Each slice names the metric that it moves (constraint C3, criterion ac1-3).
Do these steps:

1. Before the change, find the metric in the baseline file. Use a newer report when one exists.
2. After the change merges, wait until the sample is complete. For example, ac3-4 and ac4-4 need the next 40 merged PRs.
3. Run the script on the new sample:

   ```bash
   python3 bin/token-cost.py report \
     --transcript <session.jsonl> \
     --subagents <session-dir>/subagents \
     --since <merge time of the slice PR> \
     --forge-last 40 \
     --format json > after.json
   ```

4. Run the same command with the window and forge sample of the before numbers. Write it to `before.json`.
5. Run `python3 bin/token-cost.py compare before.json after.json` and read the row of your metric.
6. Put the metric name, the before number, the after number and the script commit in the PR body and in the reconciliation evidence.
7. Do not commit `before.json` or `after.json`. They hold per-run rows.

To commit a new dated report, use `--format md` and write it under `docs/perf/`.
Run `.claude/hooks/check-private-refs-runtime.sh <file>` before you commit it.

## Metric names for the plan criteria

| Criterion | Metric in the JSON report |
|---|---|
| ac2-2 | `session.context_per_turn.mean`, `session.context_per_turn.p90`, `session.compactions` |
| ac3-4 | `forge.pure_refresh_rounds` out of `forge.refresh_events` |
| ac4-4 | `reviewers.all.ci_wait_turns`, `reviewers.all.runs_with_ci_wait`, `session.cache.rebuilds_during_ci_wait`, `forge.hours_open_to_merge_median` |
| ac6-1, ac6-2 | `session.skill_injections.<skill>` and the skills table |
| ac7-5 | `reviewers.Rex.total_tokens_median` |
| ac7-6 | `reviewers.resume_rebuilds_per_100_runs` |
| ac8-5 | `forge.records_pr_rex_rounds_mean` and the records PR table |

## Baseline corrections

The re-measurement in PR #1633 corrected one number of the 2026-10-10 reconciliation.

- **CI-wait turns**: the reconciliation says 469 turns in 195 of 350 reviewer runs. That number counted tool calls, not turns.
- Under the counting rule above, the same 350 runs have 411 CI-wait turns in 178 runs.
- All transcripts up to 2026-10-10T23:59:59Z have 420 CI-wait turns in 185 of 388 reviewer runs. The baseline file holds this number.
- The difference from 469 on the same 350 runs has four parts:
  - 50 calls were in turns with a second tool call. The rule does not count those turns.
  - 10 calls were `sleep` commands that waited for a file or a process, not for CI.
  - 4 single polls count now. The earlier count exempted the first poll of any command, and the rule exempts only the first checks call.
  - 2 single checks are exempt now, because each is the first checks call of its run.
- So 469 - 50 - 10 + 4 - 2 = 411. Cite 420 in 185 of 388 as the ac4-2 and ac4-4 baseline.

## Limits

- Context shares are estimates. The script counts 4 bytes as one token and 1,600 tokens for each image. Real usage shows about 2.5 bytes per token on prompt text.
- The shares cover the text that the transcript records. The system prompt and the tool schemas are not in the transcript.
- The forge view finds Rex, Hakim and Tariq by their review headings. A post without the heading is not counted.
- The forge view uses the commit time of a PR commit as its push time.
- A saved forge file from before the parent list was added uses the merge headline to find a base merge. A merge with a custom message is then missed.

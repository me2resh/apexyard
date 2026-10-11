# Token cost baseline 2026-10-10

Produced by `bin/token-cost.py report`. Aggregate numbers only.

| Field | Value |
|---|---|
| Window | start to 2026-10-10T23:59:59Z |
| Transcript SHA-256 (measured prefix) | `27f9dba0d56aad869ad2238544ad513a5d4e6018faa78232e81d99c67c605534` |
| Script commit | `194b31c0833e3dc9c7bd65b8f8c1a8a6421d132c` |
| Claude Code CLI versions in the transcript | 2.1.285, 2.1.289, 2.1.290, 2.1.291 |

Command:

```bash
python3 bin/token-cost.py report \
  --transcript <session.jsonl> \
  --subagents <session-dir>/subagents \
  --until 2026-10-10T23:59:59Z \
  --forge-range 1524-1617 \
  --forge-range 1618-1623 \
  --label 2026-10-10 \
  --format md
```

## Session view

| Metric | Value |
|---|---|
| API turns | 5,908 |
| Context per turn: mean / p50 / p90 / p99 / max | 489,792 / 449,231 / 849,914 / 952,578 / 966,818 |
| Compactions (near the cap) | 18 (12) |
| Compaction mean pre / post tokens | 800,830 / 53,732 |
| Input / cache creation / cache read / output | 14,972 / 28,269,343 / 2,865,406,148 / 4,348,220 |
| Main-loop cache rebuilds (after compaction) | 31 (17) |
| Main-loop CI-wait turns / cache rebuilds during a CI wait | 228 / 0 |
| Requests with 1-hour / 5-minute cache writes | 5,902 / 0 |
| AUTO CODE REVIEW banners | 144 |
| Wall hours / summed turn hours | 254.03 / 99.50 |

Context share by category (context-turns: estimated tokens x turns held before the next compaction):

| Category | Share % | Tokens (est.) |
|---|---|---|
| skill-body | 24.86 | 2,025,697 |
| assistant-output | 23.06 | 1,857,705 |
| tool-result:Bash | 10.87 | 736,250 |
| skill-reinjection | 10.35 | 436,091 |
| task-notification | 6.29 | 500,001 |
| claude-md | 3.03 | 128,077 |
| post-compaction-harness | 2.71 | 155,111 |
| hook-blocking-error | 2.38 | 179,888 |
| agent-message | 2.06 | 147,512 |
| harness-nudge | 1.98 | 160,686 |
| memory-index | 1.97 | 84,020 |
| post-compaction-file-reinject | 1.78 | 72,603 |
| compaction-summary | 1.69 | 71,787 |
| tool-result:Agent | 1.58 | 125,085 |
| image | 1.44 | 120,757 |

Skill injections (untracked or private skills are grouped as `other`):

| Skill | Injections | Mean body bytes | Compaction re-injections |
|---|---|---|---|
| approve-merge | 210 | 33,688 | 18 |
| code-review | 16 | 10,505 | 14 |
| approve-design | 18 | 11,751 | 4 |
| other | 6 | 13,588 | 11 |
| task | 12 | 9,908 | 9 |
| start-ticket | 4 | 14,778 | 7 |
| orbit | 3 | 12,288 | 11 |
| release-sync | 1 | 22,955 | 6 |
| spike-close | 1 | 11,097 | 7 |
| debug | 2 | 19,832 | 2 |
| tickets-batch | 1 | 18,564 | 3 |
| approve-architecture | 3 | 11,005 | 4 |

## Reviewer view

| Metric | All reviewers | Rex | Hakim | Tariq |
|---|---|---|---|---|
| Runs | 388 | 251 | 77 | 60 |
| First-turn context (median) | 48,841 | 49,107 | 27,525 | 28,730 |
| Total tokens (uncached input + cache writes + output) | 40,360,274 | 27,154,394 | 8,926,831 | 4,279,049 |
| Total tokens per review (median) | 89,199 | 93,744 | 100,762 | 62,105 |
| Cache-read tokens | 489,362,704 | 359,538,455 | 98,993,605 | 30,830,644 |
| Tool calls per review (mean) | 18.40 | 19.70 | 20.30 | 11.00 |
| CI-wait turns | 420 | 375 | 43 | 2 |
| Runs with a CI-wait turn | 185 | 161 | 23 | 1 |
| CI waits of 300 s or more | 32 | 30 | 2 | 0 |
| Of those, followed by a cache rebuild | 29 | 27 | 2 | 0 |
| Cache rebuilds | 59 | 45 | 11 | 3 |
| Resume rebuilds | 21 | 13 | 5 | 3 |
| Of those, after a CI-green message | 6 | 5 | 1 | 0 |
| Wall hours | 42.27 | 28.57 | 9.91 | 3.78 |

Resume rebuilds per 100 reviewer runs (CI-green messages excluded): 3.87.

Runs by cache TTL (a run with any 1-hour cache write is a 1-hour run):

| TTL | Runs | First-turn context (median) | Total tokens | Cache rebuilds | CI-wait turns |
|---|---|---|---|---|---|
| 5m | 384 | 48,851 | 38,924,240 | 58 | 419 |
| 1h | 4 | 47,620 | 1,436,034 | 1 | 1 |

Other agent types:

| Type | Runs | First-turn context (median / max) | Total tokens |
|---|---|---|---|
| Explore | 2 | 20,345 / 20,735 | 97,430 |
| backend-engineer | 2 | 49,338 / 49,362 | 834,618 |
| contrarian | 25 | 22,657 / 73,452 | 2,084,255 |
| fork | 2 | 430,256 / 580,938 | 160,479 |
| general-purpose | 23 | 33,878 / 75,006 | 2,180,343 |
| head-of-data | 6 | 58,758 / 76,853 | 471,656 |
| head-of-product | 10 | 59,962 / 76,816 | 787,392 |
| head-of-security | 9 | 52,126 / 75,816 | 667,447 |
| platform-engineer | 7 | 50,221 / 77,483 | 859,791 |
| product-analyst | 8 | 58,802 / 76,852 | 618,167 |
| qa-engineer | 1 | 34,202 / 34,202 | 61,805 |
| sre | 1 | 48,814 / 48,814 | 236,333 |
| tech-lead | 2 | 48,451 / 48,475 | 1,277,412 |
| ui-designer | 4 | 49,539 / 50,824 | 1,040,124 |
| ux-designer | 2 | 63,407 / 74,407 | 146,436 |
| workflow-subagent | 48 | 52,012 / 142,189 | 6,036,301 |

## Forge view (me2resh/apexyard, PRs #1524 to #1617)

| Metric | Value |
|---|---|
| Merged PRs | 40 (#1524 to #1617) |
| Rex rounds (mean / median per PR) | 93 (2.33 / 2.00) |
| PRs with 2+ / 3+ Rex rounds | 29 / 16 |
| Rex CHANGES REQUESTED rounds | 26 |
| Hakim / Tariq rounds | 33 / 3 |
| Hours from open to merge (median / mean) | 5.67 / 6.65 |
| Pure-refresh Rex rounds / refresh events | 15 / 17 |
| Records PRs (Rex rounds per records PR, mean) | 0 (0) |

## Forge view (me2resh/apexyard, PRs #1620 to #1622)

| Metric | Value |
|---|---|
| Merged PRs | 3 (#1620 to #1622) |
| Rex rounds (mean / median per PR) | 7 (2.33 / 2.00) |
| PRs with 2+ / 3+ Rex rounds | 2 / 1 |
| Rex CHANGES REQUESTED rounds | 4 |
| Hakim / Tariq rounds | 0 / 0 |
| Hours from open to merge (median / mean) | 0.67 / 3.34 |
| Pure-refresh Rex rounds / refresh events | 0 / 0 |
| Records PRs (Rex rounds per records PR, mean) | 3 (2.33) |
| Rex rounds per records PR | #1620: 4, #1621: 1, #1622: 2 |

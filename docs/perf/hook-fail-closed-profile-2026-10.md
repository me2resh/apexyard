# Hook timing profile for the fail-closed gates: October 2026

## Scope and method

This profile supports me2resh/apexyard#1623.
It sets the `timeout` value for two hook entries in `.claude/settings.json`:
the `dispatch-bash.sh` entry and the `require-active-ticket.sh` entry.
Both entries also set `onFailure` to `block`.
See `docs/hooks-fail-closed.md` for the behavior.

The host is macOS 27.0.1 on arm64, with `/bin/bash` 3.2.57.
Claude Code is version 2.1.296.
The repository base is `db03eb0` on `dev`.
All times are in milliseconds.
p50 is the median. p95 is the 95th percentile.
The percentile method is nearest rank:
sort the n samples and take the value at rank ceil(p x n).
`bin/hook-timing-profile.py` computes the numbers.

### Source 1: real Claude Code sessions with `--debug-file`

`claude --debug-file <path>` records one line for each hook run:

```text
Hooks: PreToolUse:Bash <command> finished with status 0 (547ms)
```

The duration in that line is the wall time of the complete hook command,
including the `bash -c` wrapper from `.claude/settings.json`.
This source is the real Claude Code measurement.

Two headless sessions ran in the repository with `claude -p --model haiku`.
The prompt told the model to make one tool call at a time, never in parallel.
The Bash session made 112 calls from eight read-only commands.
The Write session made 64 writes of new files to a path that the ticket gate
does not exempt, so each call took the full gate path.
An active ticket marker was present.

`bin/hook-timing-profile.py parse <debug log> <script>` read the two logs.

### Source 2: a faithful harness for routes that a short session does not reach

A model session cannot safely run `git push` or a merge.
For those routes, `bin/hook-timing-profile.py run` pipes a payload into the
exact wrapper command from `.claude/settings.json` and times each call.
The command in the payload is never run.
Only the hooks see it.
This harness measures the same wrapper and script as Claude Code.
It does not include the time that Claude Code spends to start the hook.
The merge and PR routes call the tracker over the network, so they vary most.

## Results

| Hook | Route | Source | n | p50 | p95 | max |
|------|-------|--------|---|-----|-----|-----|
| `dispatch-bash.sh` | Bash, read-only commands | `--debug-file` | 112 | 534 | 577 | 872 |
| `require-active-ticket.sh` | Write, in-tree path | `--debug-file` | 64 | 192 | 207 | 223 |
| `require-migration-ticket.sh` | Write, in-tree path (same entry group, for context) | `--debug-file` | 64 | 122 | 138 | 156 |
| `dispatch-bash.sh` | `echo hello` | harness | 30 | 497 | 548 | 569 |
| `dispatch-bash.sh` | `git status --short` | harness | 30 | 503 | 589 | 609 |
| `dispatch-bash.sh` | `git commit -m ...` | harness | 30 | 762 | 834 | 2184 |
| `dispatch-bash.sh` | `git push origin HEAD` | harness | 30 | 928 | 1001 | 1354 |
| `dispatch-bash.sh` | `gh pr create ...` | harness | 30 | 1956 | 2226 | 2309 |
| `dispatch-bash.sh` | `gh pr merge N --squash` | harness | 30 | 2607 | 2748 | 2883 |

The ticket gate runs inside `dispatch-bash.sh` for every Bash call.
So the `dispatch-bash.sh` rows already include the ticket gate time on the Bash path.

## Timeout rule and chosen values

The rule is: timeout >= 5 x p95, and never under 10 seconds.
Use the slowest route p95 of the entry, not the median route.
The fail-closed gate blocks the call when the timeout ends it.
A timeout that is too short would block valid merges.

| Entry | Slowest p95 | 5 x p95 | Floor | Chosen timeout |
|-------|-------------|---------|-------|----------------|
| `dispatch-bash.sh` (Bash matcher) | 14885 (`gh pr merge`, #1770 chain after #1796, see below) | 74425 | 10000 | 75 seconds |
| `require-active-ticket.sh` (Edit, Write, MultiEdit matcher) | 207 | 1035 | 10000 | 10 seconds |

The `dispatch-bash.sh` value is 75 seconds, above the 74.4 second minimum
from the #1770 chain after #1796. That is inside the CEO 60–75 band
(AgDR-0256 decision 4). A merge that waits longer than 75 seconds for the
tracker fails closed. The operator can retry it.

### Merge route after AgDR-0256 (me2resh/apexyard#1759)

The first table measured a merge that the review gate blocked early.
A full merge route runs all four gates and the head recheck.
It depends on the network: route p95 is about the always-on time
plus the call count times the per-call cost.

AgDR-0256 cut the full route from 9 to 13 forge calls to 5 or 6.
The measurement below runs the real dispatcher and the real four gates
in a sandbox ops root with fixture approval markers, through
`/bin/bash` 3.2 on macOS, n=30, for a plain merge with checks present.
"Before" is upstream `dev` `4ef5fee`. The other always-on hooks are stubs,
so the rows show the merge-gate part of the route.

| Host | Calls before / after | p95 before | p95 after | max after |
|------|----------------------|------------|-----------|-----------|
| macOS, real GitHub API (about 1.2 s per call), open 5-file PR | 9 / 5 | 13015 | 9567 | 10928 |
| Simulated #1759 Linux host (`gh` shim, 0.9 to 1.9 s per call) | 9 / 5 | 16669 | 9661 | 11164 |

The #1759 host itself was not available. The second row replays its
per-call latency. Its p95 is the larger one, so the profile line uses it.
NFR-1 of AgDR-0256 (p95 of 15 seconds or less on that host) is met.

A branch with a chain of "merge dev into branch" commits is slower.
When the Rex marker is on an older commit, the review gate walks the
chain with one forge call for each step. PR #1770 has 4 steps:

| Host | Calls after #1759 / after #1796 | p95 after #1759 | p95 after #1796 |
|------|----------------------------------|-----------------|-----------------|
| macOS, real GitHub API, squash merge of #1770 | 10 / 6 | 11469 | 16542 |
| Simulated #1759 host (recorded responses, 0.9 to 1.9 s per call) | 10 / 6 | 18986 | 14885 |

Issue #1796 batches the walk into one GraphQL call and adds a per-call `gh`
limit (`apexyard_gh`, default 20 s). Simulated p95 is 14885 ms (NFR-1 met).
5 x that p95 is 74.4 seconds, so the dispatcher timeout is 75 seconds.

No document gives a timeout override in `.claude/settings.local.json`.
Nothing yet shows which `timeout` wins when two entries merge.

`.claude/hooks/tests/test_settings_fail_closed.sh` reads the lines below and
checks the two timeouts in `.claude/settings.json` against them.

```text
profile: dispatch-bash.sh p95_ms=14885
profile: require-active-ticket.sh p95_ms=207
```

## Limits of this profile

- The numbers come from one macOS machine. A Linux CI runner has different timings.
- The harness routes do not include Claude Code's own hook start time.
- A sandbox without network access makes the tracker routes fail fast, not slow.
- A hook speed-up is outside this profile. Issue #1613 tracks hook speed-ups.
  A speed-up lowers the p95 and does not require a timeout change.

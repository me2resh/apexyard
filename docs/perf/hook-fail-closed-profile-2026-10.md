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
| `dispatch-bash.sh` (Bash matcher) | 2748 (`gh pr merge`) | 13740 | 10000 | 20 seconds |
| `require-active-ticket.sh` (Edit, Write, MultiEdit matcher) | 207 | 1035 | 10000 | 10 seconds |

The `dispatch-bash.sh` value is 20 seconds, above the 13.74 second minimum.
The extra margin covers slow tracker responses on the merge and PR routes.
A merge that waits longer than 20 seconds for the tracker fails closed.
The operator can retry it.

`.claude/hooks/tests/test_settings_fail_closed.sh` reads the lines below and
checks the two timeouts in `.claude/settings.json` against them.

```text
profile: dispatch-bash.sh p95_ms=2748
profile: require-active-ticket.sh p95_ms=207
```

## Limits of this profile

- The numbers come from one macOS machine. A Linux CI runner has different timings.
- The harness routes do not include Claude Code's own hook start time.
- A sandbox without network access makes the tracker routes fail fast, not slow.
- A hook speed-up is outside this profile. Issue #1613 tracks hook speed-ups.
  A speed-up lowers the p95 and does not require a timeout change.

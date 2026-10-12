---
id: AgDR-0229
timestamp: 2026-10-12T00:30:00Z
agent: platform-engineer
model: claude-sonnet-5-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: patterns
---

<!-- When this template creates an artifact, use the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# AgDR-0229: Skip provably empty process launches in the merge parser and weight the test shards

> Skip five process launches with a known result. Assign test shards by measured weight. This cuts macOS hook test cost. It adds one data file and one shell guard at each skip.

## Context

Issue #1613 asks for a lower macOS cost for the hook tests. The first round (PR #1615) cut redundant config-root walks. Profiling in `docs/perf/hook-test-profile-2026-10-round2.md` shows the next cost.

One call of `block-merge-on-red-ci.sh` takes about 150 ms on macOS. Most of that time is the launch of `awk`, `grep`, `sed`, `tr` and `head` from `_lib-extract-pr.sh`. Several of those launches cannot change the result for the input they receive.

CI runs the hook tests in four macOS shards. The runner assigned test k to shard `k % 4` in alphabetical order. Slow tests cluster in the alphabet. The shards took 310 s to 498 s in a recent run.

The merge gates are control gates. A change in a shared library must not narrow any gate. AgDR-0224 sets the rule that each fallback is at least as strict as its awk path.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Guard each launch that cannot change the result | Same output and status for every input. No state. Easy to prove | Saves only the launches that the guards can prove empty |
| Cache results of the join and scrub functions in variables | Larger saving | The functions run in command substitutions, so each call site changes. A cache can hide a changed `PATH` or a stubbed `awk` in tests |
| Rewrite the parser in one awk program | Largest saving | Out of scope in the ticket. High review cost for a control gate |
| Keep round-robin shards | No new file | Shard time depends on where slow tests fall in the alphabet |
| Assign shards by measured weight (chosen) | Shard totals stay close. Falls back to round-robin without the file | A weights file needs a refresh when tests change a lot |

## Decision

Chosen: **guard each launch that cannot change the result, and assign shards by weight.**

### Guards in `_lib-extract-pr.sh`

Each guard skips a launch only when the launch would produce the same stdout and the same status.

- `_has_argv_merge` returns 1 when the text has no `"`, `'` or backtick. Every pattern in that function starts with a quoted binary element, so none can match.
- `_join_shell_continuations` prints its input when the input has no backslash and `awk` is on `PATH`. The awk join program returns such input unchanged. The missing-`awk` fallback still runs when `awk` is absent, so the strict fallback stays in force. `join_shell_continuations` in `_lib-awk-fallback.sh` is not changed, so `dispatch-bash.sh` keeps its own fail-closed path.
- `_forge_from_command` prints `gh` when the text has no `glab`. The pattern needs that word.
- `extract_pr_number` skips the API path greps when the text has no `pulls/` or no `merge_requests/`. The patterns need those words.
- `merge_command_uses_variable` skips the wrapper grep when the text has no `tracker_pr_merge`. The pattern needs that word.

`test_extract_pr_fast_paths.sh` compares the new functions with verbatim copies of the old ones on 39 inputs. It also counts launches through `PATH` shims. The count test fails on the old code.

### Weighted shards in `bin/run-hook-tests.sh`

When `bin/hook-test-weights.txt` exists and the shard count is above 1, the runner packs tests by the longest-processing-time rule. It sorts tests by weight, heaviest first, and gives each test to the shard with the smallest total. A test that is not in the file gets weight 10. A missing or empty file keeps round-robin. Every test lands in exactly one shard for every shard count. `test_run_hook_tests_shard.sh` checks this for 1 to 8 shards.

## Consequences

- The merge-gate libraries run fewer processes for commands that carry no quotes, no backslash, or none of the guarded words. Gate decisions do not change.
- The `_join_shell_continuations` guard returns the exact join for backslash-free input even when `awk` exists but fails. The old code used the broad fallback in that case. The result now equals the healthy-`awk` result.
- The weights file is a measured snapshot. A refresh keeps the shards balanced. A stale file only makes the balance worse, never the coverage.
- Round-robin membership changes whenever a test is added. Weighted membership changes less, because the heavy tests keep their place.
- Rejected for now: caching join and scrub results. The proposal is in the profile report with its risks.

## Artifacts

- Issue: me2resh/apexyard#1613
- Report: `docs/perf/hook-test-profile-2026-10-round2.md`
- Earlier round: AgDR-0120 "Update (#1613)", PR #1615

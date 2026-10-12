# Hook test profile, round 2: October 2026

## Scope and method

This report covers me2resh/apexyard#1613, second round, on macOS arm64 with `/bin/bash` 3.2.57.
Round 1 is in `docs/perf/hook-test-profile-2026-10.md` and PR #1615.
The base is `dev` at `9b25c83`.
A shard is one of four slices of the hook test suite that CI runs in parallel on macOS.
Wall time is the elapsed time of one test file. CPU time is user plus system time of the file and its child processes.
All times are in seconds unless the unit says milliseconds.

Method:

- A script runs each test file once, in series, with `/bin/bash`, and with the same isolation variables as `bin/run-hook-tests.sh`.
- The "before" run uses a clean checkout of the base. The "after" run uses the final working tree.
- The machine ran nothing else during these two runs.
- A first "before" run overlapped with a profiling job. It is discarded. It overstated the saving.
- Each number is one run. Untouched files differ by up to 1 second between the two runs. Treat a difference under 5% as noise.
- Per-call numbers are the median of 20 or 30 runs of one hook in a disposable sandbox.

This is local evidence. It does not predict the CI saving.

## Result

| Measure | Before | After | Change |
| --- | ---: | ---: | ---: |
| Whole suite in series, wall | 1018.3 s | 977.3 s | -4.0% |
| Whole suite in series, CPU | 832.5 s | 804.1 s | -3.4% |
| Ten slowest named tests, wall | 341.1 s | 309.7 s | -9.2% |
| Ten slowest named tests, CPU | 281.6 s | 263.1 s | -6.6% |
| Slowest macOS shard, wall | 272.0 s | 249.6 s | -8.2% |
| Slowest macOS shard, CPU | 224.5 s | 201.2 s | -10.4% |
| `block-merge-on-red-ci.sh`, one call | 139 ms | 81 ms | -42% |

The whole-suite figure includes the two new test files (4.6 s and 0.9 s of extra wall time).
The 30% target in the ticket is not met.
The ticket stays open for the remaining proposals below.

## Per-test timings

These are the ten tests that the ticket names, plus four tests that the changes also touch.

| Test file | Wall before | Wall after | CPU before | CPU after | Wall change |
| --- | ---: | ---: | ---: | ---: | ---: |
| `test_check_private_refs_push.sh` | 50.3 | 47.2 | 38.3 | 35.7 | -6% |
| `test_require_orbit_slice_for_ticket.sh` | 32.5 | 32.4 | 29.2 | 29.2 | 0% |
| `test_merge_command_data.sh` | 46.9 | 41.3 | 43.7 | 38.4 | -12% |
| `test_require_migration_ticket.sh` | 52.6 | 52.2 | 43.6 | 43.5 | -1% |
| `test_block_merge_on_red_ci.sh` | 39.7 | 24.0 | 23.9 | 17.1 | -40% |
| `test_block_unreviewed_merge.sh` | 28.2 | 22.2 | 21.7 | 18.0 | -21% |
| `test_block_private_refs.sh` | 19.2 | 19.2 | 16.0 | 16.0 | 0% |
| `test_require_active_ticket_bash.sh` | 36.2 | 35.8 | 31.7 | 31.9 | -1% |
| `test_block_ambient_tracker_repo.sh` | 15.5 | 15.5 | 14.3 | 14.0 | 0% |
| `test_detect_bash_write.sh` | 20.0 | 19.9 | 19.2 | 19.3 | -1% |
| Ten tests, total | 341.1 | 309.7 | 281.6 | 263.1 | -9.2% |
| `test_lib_merge_behind.sh` | 8.3 | 6.8 | 3.2 | 3.3 | -18% |
| `test_extract_pr.sh` | 22.6 | 16.4 | 22.4 | 15.8 | -27% |
| `test_dispatch_bash.sh` | 17.9 | 15.8 | 12.8 | 11.3 | -12% |
| `test_tracker_aware_hooks.sh` | 19.5 | 19.3 | 15.8 | 15.7 | -1% |

Five of the ten tests do not change. No production code and no fixture changed on their paths.
Their cost is hook run time: about 0.4 to 0.6 s per hook call on macOS.

## Shard timings

CI runs `bin/run-hook-tests.sh --shard I/4` on four macOS jobs.
The old runner gave test k to shard `k % 4`, in alphabetical order.
The totals below add the measured serial time of each test in the shard.
The "after" weights come from the same run. The balance is therefore the best case.

| Shard | Tests before | Wall before | Wall after | CPU before | CPU after |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 63 | 233.4 | 246.9 | 186.8 | 200.9 |
| 2 | 63 | 258.4 | 244.8 | 206.5 | 201.2 |
| 3 | 63 | 272.0 | 249.6 | 224.5 | 201.0 |
| 4 | 63 | 254.5 | 236.0 | 214.7 | 201.0 |
| Slowest | | 272.0 | 249.6 | 224.5 | 201.2 |
| Spread (slowest minus fastest) | | 38.6 | 13.6 | 37.7 | 0.3 |

In the CI run of 2026-10-11, the four shards took 498, 359, 310 and 435 seconds.
That spread is larger than the local spread because CI has a different cost mix and the test list was shorter.
The expected CI gain is a smaller spread. It is not measured.

## Where the time goes

### 1. Process launches in the merge parser

One call of `block-merge-on-red-ci.sh` for `gh pr merge 300 --repo me2resh/apexyard --squash` ran about 40 launches of `awk`, `grep`, `sed`, `tr` and `head`.
Many of them cannot change the result:

- `_has_argv_merge` ran `tr` and six `grep` calls on text with no quote character, several times per hook call. Each pattern needs a quote.
- `_join_shell_continuations` ran `awk` about ten times on the same text. The text had no backslash, so `awk` returned it unchanged.
- `extract_pr_number`, `_forge_from_command` and `merge_command_uses_variable` ran `grep` pipelines for words that the text did not contain.

The final code skips these launches with a `case` test.
A single call of the red-CI hook fell from 139 ms to 81 ms (median of 30 runs, two rounds).
The same functions run in four merge gates and in the dispatcher path.

### 2. First run of a new executable

On this Mac, the first run of an executable file with new content takes 135 to 260 ms.
A copy of content that has already run takes about 36 ms.
A hard link of such a file takes 19 ms.
A script that `bash` reads as an argument takes 18 ms.
Eight samples each, run twice:

| Variant | First run, ms |
| --- | ---: |
| New file, new content, run by path | 134 to 260 |
| Copy of a file that already ran | 34 to 126 (median 36) |
| Hard link of a file that already ran | 18 to 22 |
| New file run as `bash file` | 18 to 20 |

Several merge-gate tests wrote a fresh `gh` mock for each case.
The script text held the case's temporary path and mode, so every case had new content.
`test_block_merge_on_red_ci.sh` has 139 cases. Its wall time exceeded its CPU time by 15.8 s.
The tests now write the same text for every case and read the mode from a small file.
The wall time of that test fell from 39.7 s to 24.0 s.
I measured this on my machine only. I did not measure whether the CI runners show the same effect.

### 3. Fixture setup in the push test

`test_check_private_refs_push.sh` built 38 repository pairs.
Each pair ran about ten `git` commands (init, three config calls, add, commit, bare clone, remote add, config, fetch, branch).
The test now builds one pair, copies it for each case, and fixes the origin URL and the `insteadOf` key.
The wall time fell from 50.3 s to 47.2 s. Hook and `git push` calls dominate the rest.

### 4. Shard imbalance

Slow tests cluster in the alphabet. See the shard table above.

### 5. Dispatcher cost per call

`dispatch-bash.sh` takes about 500 ms for a plain command such as `ls -la src` in a sandbox with a cold resolution cache.
Real sessions record a median of 534 ms for read-only Bash commands (112 calls, see `docs/perf/hook-fail-closed-profile-2026-10.md`).
Each of about nine child hooks pays a process start, a `cat`, a `jq` call and its own library sourcing.
The profile run shows most of the time spent before the first line of each child hook.
No change in this round targets that cost.

## Changes

1. `.claude/hooks/_lib-extract-pr.sh`: five guards that skip launches with a known result. See AgDR-0229.
2. `bin/run-hook-tests.sh` and `bin/hook-test-weights.txt`: weighted shard assignment. A missing weights file keeps round-robin.
3. `test_check_private_refs_push.sh`: one pristine repository pair, copied per case.
4. Five test files write the same mock text in every case.
5. `test_extract_pr_fast_paths.sh`: 39-input parity check against the old functions and a launch budget check.
6. `test_run_hook_tests_shard.sh`: new checks for the weighted shards. Existing checks are unchanged.

## Safety

- Each guard returns the same stdout and the same status as the old code. The parity test compares them on 39 inputs, including backslash continuations, comments, quotes and glab shapes.
- The launch budget test fails on the old code. I confirmed this by running it against the base.
- `join_shell_continuations` in `_lib-awk-fallback.sh` is not changed. `dispatch-bash.sh` keeps its own failure path.
- The `awk`-missing fallback of `_join_shell_continuations` still runs when `awk` is not on `PATH`.
- `block-unreviewed-merge.sh` and `block-merge-on-red-ci.sh` are not edited. Their decisions do not change.
- No test case is removed or weakened. Pass counts match the base for every edited file.
- The shard test proves that every test lands in exactly one shard for 1 to 8 shards.

## Remaining proposals

These are not implemented. None is measured, so the sizes are estimates from launch counts.

- Cut the cost of each child hook start in `dispatch-bash.sh`. Merge `cat` and `jq` calls, and load libraries once. This targets about 50 ms per child hook. It touches every gate.
- Remove repeated merge-span greps in `_lib-extract-pr.sh`. Several calls read the same span. Passing the span between functions would save an estimated 25 ms per merge call.
- Cache the result of `_scrub_merge_command` for one command. It needs a design that survives a changed `PATH` in tests.
- Reduce `git` launches in `require-orbit-slice-for-ticket.sh` and `require-migration-ticket.sh`. Round 1 measured 47 and 58 launches per call.
- Add a fifth macOS shard if CI wall time matters more than runner minutes.

## Validation

- `test_extract_pr_fast_paths.sh`, `test_run_hook_tests_shard.sh` and `test_check_private_refs_push.sh` pass.
- Every file in the full serial run passes, except `test_dependency_audit_ecosystems.sh`. It fails on the base too, because Apple's Python 3.9 has no `tomllib`.
- `shellcheck -S warning -x` is clean on every changed shell file.

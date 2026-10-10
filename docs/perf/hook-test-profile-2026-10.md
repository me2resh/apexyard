# Hook test profile: October 2026

## Scope and method

This profile covers me2resh/apexyard#1613 on macOS, using `/bin/bash` 3.2.57 on arm64.
A fingerprint records configuration-file metadata for cache freshness.
A sandbox is an independent temporary test directory.
AgDR means Agent Decision Record.
The worktree starts at `20f721c2` on `perf/GH-1613-profile-slow-hook-tests`.
The supplied CI baseline reports 731 seconds for these ten files.
Local baseline runs total 432.345 seconds.
Local measurements do not establish a CI saving.

Wall times cover the complete test process, including fixture setup and cleanup.
Python `time.monotonic()` measures each `/bin/bash .claude/hooks/tests/test_NAME.sh` invocation.
The ten files run serially, without concurrent test workloads.
Process profiling uses a separate, unchanged repository snapshot.
Its instrumentation overhead is excluded from wall-time comparisons.

PATH shims log launches of `jq`, `awk`, `sed`, `git`, `grep`, and fixture tools.
Each shim executes the original tool with unchanged arguments and streams.
An interpreter startup callback records the script name, then removes itself before hook logic runs.
A continuous DEBUG trap was discarded because it disturbed Bash 3.2 `PIPESTATUS`.
Absolute tool paths and test mocks can bypass shims.
Counts describe observed launches, not all kernel process creation.

Dispatch inputs use `jq -nc --arg c "$command" '{tool_name:"Bash",tool_input:{command:$c}}'`.
Each command runs 20 times in the same disposable fixture.
The report uses the median wall time.
The fixture has an origin, empty approval state, and a failing `gh` stub.
The read command returns 0.
The unapproved merge and source write return 2.
Commands are inspected by hooks and never executed.

## Before and after wall times

The final patch reduces the ten-file total from 432.345 to 363.920 seconds.
The observed saving is 15.8%, below the 30% target.
All ten baseline and final timed runs pass.
The following cost attribution uses launch counts, sourcing samples, and the effect of the patch.
It is an inference, not an exclusive CPU-time measurement.
Each complete-file timing is one sample.
Untouched tests also show run-to-run variation.
Negative savings remain in the aggregate.

| Test file | Before, s | After, s | Hook calls | Likely top cost | Applied fix | Observed saving, s |
| --- | ---: | ---: | ---: | --- | --- | ---: |
| `test_check_private_refs_push.sh` | 62.592 | 53.206 | 162 | History, transport, and path resolution | One root per load | 9.386 |
| `test_require_orbit_slice_for_ticket.sh` | 64.528 | 32.021 | 130 | Configuration and registry resolution | One root and disabled fingerprint skip | 32.507 |
| `test_merge_command_data.sh` | 57.562 | 46.889 | 108 | Repeated grep parsing and root resolution | One root per load | 10.673 |
| `test_require_migration_ticket.sh` | 69.852 | 59.361 | 85 | Tracker configuration and repeated fixture construction | Pristine fixture and one root | 10.491 |
| `test_block_merge_on_red_ci.sh` | 42.813 | 48.475 | 139 | Merge parsing with many grep and awk launches | Shared library fixes only | -5.662 |
| `test_block_unreviewed_merge.sh` | 31.699 | 30.311 | 117 | Fixture copies, merge parsing, and config reads | Pristine fixture and one root | 1.388 |
| `test_block_private_refs.sh` | 17.809 | 19.393 | 113 | Grep and sed command parsing | One root per load | -1.584 |
| `test_require_active_ticket_bash.sh` | 42.152 | 36.374 | 155 | Fixture construction and write-detector parsing | Pristine fixture and one root | 5.778 |
| `test_block_ambient_tracker_repo.sh` | 24.312 | 17.975 | 95 | Repeated Git and configuration resolution | One root and disabled fingerprint skip | 6.337 |
| `test_detect_bash_write.sh` | 19.026 | 19.915 | 0 | Write-detector grep and awk parsing | No matching production path changed | -0.889 |
| Total | 432.345 | 363.920 | | | | 68.425 |

The observed savings are the measured expectation for another comparable local run.
They do not predict the CI saving or a repeated-run confidence interval.

## Dispatch medians

| Command | Before, ms | After, ms | Return code | Runs per phase |
| --- | ---: | ---: | ---: | ---: |
| `git status --short` | 560.493 | 508.961 | 0 | 20 |
| `gh pr merge 7 --repo demo/service --squash` | 2192.376 | 1236.074 | 2 | 20 |
| `printf x > src/app.ts` | 1564.678 | 1237.025 | 2 | 20 |

Every dispatch median improves.
Every run retains its baseline return code.
The fixture receives the current hook files before each phase.

## Changes and safety

Three test files build a pristine fixture once, then copy it for each case.
Copies retain independent Git repositories, hook files, markers, and configuration.
No test case shares mutable state with another case.
The partial-install active-ticket fixture still omits `_lib-path-resolve.sh`.
The migration factory still returns a physical path.

Two library changes remove redundant work.
`_config_load` resolves its root once for defaults, overrides, and the optional fingerprint.
Its root cache and completion flag are local to that load.
The flag also caches an empty lookup.
Original path helpers retain their return statuses, including POSIX errexit failures.
It cannot persist into a later load or another working directory.
Existing configuration merge, warning, and fallback behavior remains intact.

`_resolution_cache_current_fingerprint` returns `UNKNOWN` immediately when caching is disabled or lacks a session.
Cache reads and writes already refuse those states.
Enabled caches retain their signatures, freshness checks, and same-second write protection.
New regressions check disabled fingerprints, root scope across working directories, and POSIX error status.
Existing cache tests still check invalidation and enabled-cache reuse.

These library changes are implementation choices for the operator's AgDR decision.
This patch adds no AgDR.
It changes no gate matcher, approval rule, or allow/block branch.
It adds no library and requires no new sandbox dependency.
It leaves `.github/workflows/tests.yml` and `bin/run-hook-tests.sh` unchanged.

## Library sourcing cost

These medians include a fresh Bash process and one library source.
Each library runs 20 times in the unchanged snapshot.
They exclude function execution and configuration resolution.

| Library | Startup plus source, ms |
| --- | ---: |
| `_lib-read-config.sh` | 5.647 |
| `_lib-resolution-cache.sh` | 2.370 |
| `_lib-ops-root.sh` | 2.137 |
| `_lib-portfolio-paths.sh` | 6.058 |
| `_lib-tracker.sh` | 3.791 |
| `_lib-extract-pr.sh` | 7.578 |
| `_lib-detect-bash-write.sh` | 6.294 |
| `_lib-command-scrub.sh` | 2.239 |

## Representative shell traces

Isolated `bash -x` runs use `PS4='+${BASH_SUBSHELL}|'`.
Tracing writes diagnostics outside the functional test assertions.
The table counts source operations and upward transitions in traced subshell depth.
Transitions provide an observed lower bound, because pipeline traces can interleave.
They are not kernel process counts.
The fixture has all libraries installed.
Individual tests also exercise partial installations.

| Hook or library | Inspected command | Source operations | Subshell regions |
| --- | --- | ---: | ---: |
| `check-private-refs-push.sh` | `Push startup with no refs` | 5 | 5 |
| `require-orbit-slice-for-ticket.sh` | `gh issue create --repo demo/service --title '[Feature] Demo' --body 'plain body'` | 12 | 109 |
| `block-unreviewed-merge.sh` | `gh pr merge 7 --repo demo/service --squash` | 13 | 130 |
| `block-merge-on-red-ci.sh` | `gh pr merge 7 --repo demo/service --squash` | 4 | 53 |
| `block-private-refs-in-public-repos.sh` | `gh issue create --repo me2resh/apexyard --title '[Task] Demo' --body 'plain body'` | 6 | 67 |
| `require-migration-ticket.sh` | `printf x > migrations/001.sql` | 12 | 129 |
| `require-active-ticket.sh` | `printf x > src/app.ts` | 14 | 144 |
| `block-ambient-tracker-repo.sh` | `gh issue view 7` | 9 | 46 |
| `_lib-detect-bash-write.sh` | `git status --short` | 3 | 10 |

The numbered merge blocks because the fixture cannot resolve its head SHA.
The source writes block because the fixture has no active ticket.
The detector-only read returns 1, which means no write was detected.
The ORBIT fixture permits its create because it has no registry.
The push startup trace excludes history scanning and transport.
The full push profile below includes both.

## Process launches and fixture setup

These counts come from successful shim runs of all ten unchanged test files.
Hook counts include copied hooks and instrumented migration baselines.
The push file starts 82 framework hooks and 80 Git lifecycle hooks.
The merge-data file also performs 91 assertions outside its 108 hook calls.
The detector file performs 368 library assertions and starts no hook process.
Three unreviewed-merge POSIX calls and one red-CI POSIX call ignore `BASH_ENV`.
Their explicit passing cases supply those four invocation counts.
Other counts come from interpreter startup records.

Git prepends its own executable directory when it launches Git hooks.
That directory can bypass the Git shim.
Mocks and absolute executable paths also bypass shims.
Per-hook averages therefore describe observed PATH launches.
They exclude test fixture work.

| Test suffix | Hook calls | jq/call | awk/call | sed/call | git/call | grep/call |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `check_private_refs_push` | 162 | 1.93 | 2.59 | 5.84 | 0.48 | 4.29 |
| `require_orbit_slice_for_ticket` | 130 | 12.83 | 12.81 | 2.92 | 46.60 | 0.70 |
| `merge_command_data` | 108 | 2.70 | 18.59 | 13.07 | 19.67 | 71.89 |
| `require_migration_ticket` | 85 | 14.61 | 5.73 | 7.53 | 57.99 | 10.14 |
| `block_merge_on_red_ci` | 139 | 4.21 | 12.42 | 4.91 | 1.58 | 33.93 |
| `block_unreviewed_merge` | 117 | 2.09 | 9.83 | 6.88 | 3.78 | 27.21 |
| `block_private_refs` | 113 | 1.00 | 8.74 | 17.44 | 1.98 | 26.30 |
| `require_active_ticket_bash` | 155 | 2.98 | 7.33 | 1.98 | 4.72 | 41.03 |
| `block_ambient_tracker_repo` | 95 | 2.56 | 1.61 | 4.73 | 25.39 | 2.65 |
| `detect_bash_write` | 0 | — | — | — | — | — |

For the detector assertions, totals are 2,018 awk, 7,069 grep, and 267 sed launches.
The following setup counts exclude launches attributed to hooks.
They include auxiliary project repositories and temporary capture files.

| Test suffix | mktemp | cp | git init | git commit | git clone |
| --- | ---: | ---: | ---: | ---: | ---: |
| `check_private_refs_push` | 43 | 391 | 56 | 107 | 42 |
| `require_orbit_slice_for_ticket` | 3 | 4 | 3 | 4 | 0 |
| `merge_command_data` | 2 | 5 | 1 | 0 | 0 |
| `require_migration_ticket` | 86 | 804 | 96 | 96 | 0 |
| `block_merge_on_red_ci` | 140 | 453 | 0 | 0 | 0 |
| `block_unreviewed_merge` | 115 | 800 | 1 | 134 | 0 |
| `block_private_refs` | 116 | 0 | 0 | 0 | 0 |
| `require_active_ticket_bash` | 167 | 1399 | 162 | 162 | 0 |
| `block_ambient_tracker_repo` | 2 | 1 | 18 | 2 | 0 |
| `detect_bash_write` | 1 | 0 | 0 | 0 | 0 |

Fresh Bash fixture samples include construction and removal.
Each factory runs five times.
The median is 92.6 ms for migration, 62.1 ms for unreviewed merge, and 69.4 ms for active ticket.
The patch builds those fixtures once and copies their pristine state for subsequent cases.

## Remaining proposals

The final aggregate saving is 15.8%.
The 30% target remains unmet.
This patch retains the requested limit of two hook/library fixes.
The following proposals are unimplemented and unmeasured.
Their expected savings require separate benchmarks and gate-parity checks.

- Skip a second raw merge scan when joined text equals the original text.
- Batch equivalent grep patterns in merge argv detection.
- Batch equivalent write-detector patterns without changing interpreter or quoting rules.
- Extract multiple JSON fields together in individual hooks, preserving malformed-input fallbacks.
- Reuse red-CI fixtures within explicit groups that do not alter their libraries or mocks.

Parser batching targets the largest remaining launch counts.
It requires a separate review of parser failures and conservative fallbacks.
No saving from these proposals contributes to this report.

## Validation

All 203 top-level hook test files ran under `/bin/bash`, with four concurrent test processes.
The initial run passed 200 files and failed three.
All ten profiled files, all four edited test files, and all eleven ticket-required safety suites pass.
The resolution-cache test passes 13 cases with zero failures.
`git diff --check` passes.

The broad run is not wholly green:

- `test_dependency_audit_ecosystems.sh`: Python 3.9 lacks `tomllib`; 57 cases pass and 11 fail. The unchanged snapshot produces the same result. With installed Python 3.13, all 68 cases pass.
- `test_lib_self_location_cwd_anchor.sh`: seven historical BASE assertions fail because BASE defaults to HEAD, which already contains the fixes. Current-code assertions pass. The historical assertions read unchanged committed files through `git show`. An older BASE reference recovers six assertions but still fails the block-main-push historical assertion.
- `test_token_efficiency_wave1.sh`: the SessionStart banner exceeds 600 characters. The unchanged snapshot also fails this invariant (1124 characters); the working tree reports 1096. A standalone rerun still fails.

Exact diagnostic and rerun commands:

```sh
PATH="$PWD/.hook-profile/python-bin:$PATH" /bin/bash .claude/hooks/tests/test_dependency_audit_ecosystems.sh
APEXYARD_TEST_BASE_REF=6d7d3f9c^ /bin/bash .claude/hooks/tests/test_lib_self_location_cwd_anchor.sh
/bin/bash .claude/hooks/tests/test_token_efficiency_wave1.sh
```

The temporary `python-bin/python3` symlink points to `/opt/homebrew/bin/python3.13`.
The Python rerun passes; the other two commands still fail.
The scratch directory is removed after reporting.
Final known file outcomes, including the Python rerun, are 201 pass and 2 fail.
The all-tests-pass requirement and the 30% performance target remain unmet.
No unrelated test or production gate was edited to clear these failures.

<details>
<summary>Exact initial regression commands and file results (200 pass, 3 fail)</summary>

Each command ran once in the broad regression batch.
Counts refer to test files, not assertions.

| Command | Pass | Fail |
| --- | ---: | ---: |
| `/bin/bash .claude/hooks/tests/test_active_ticket_process_budget.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_active_ticket_resolver.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_agdr_marker_supersession.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_agdr_skill.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_agent_role_selection.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_agent_routing_sync_and_drift.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_approve_merge_worktree.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_artifact_completeness.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_audit_history.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_awk_fallback.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_awk_fallback_missing.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_ambient_tracker_repo.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_main_push.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_main_push_heredoc.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_merge_on_red_ci.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_onboarding_in_git.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_private_refs.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_private_refs_public_entry.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_privileged_escalation.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_reviewer_repo_mutation.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_reviewer_worktree_add_scope.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_block_unreviewed_merge.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_git_hooks_installed.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_jq_installed.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_private_refs_empty_lists.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_private_refs_non_utf8.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_private_refs_push.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_private_refs_staged.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_upstream_drift.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_check_writing_profile.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_ci_snapshot_proofs.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_clear_active_reviewer_marker.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_clear_onboarding_depth_mode_marker.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_clear_onboarding_glossary_seen_marker.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_command_scrub_must_block.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_command_scrub_regressions.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_config_build_isolation.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_config_get_backslash_escape.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_config_get_strips_cr.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_config_merge_require_up_to_date.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_config_merge_semantics.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_config_warn_dropped_defaults.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_conformance_assert_block_message.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_conformance_publish_badge.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_cursor_session_pin.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_cursor_skill_dedupe.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_dependency_audit_ecosystems.sh` | 0 | 1 |
| `/bin/bash .claude/hooks/tests/test_depth_mode.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_detect_bash_write.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_detect_bash_write_1502.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_detect_deprecated_config.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_detect_role_trigger.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_detect_skill_intent.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_dev_compat_rows.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_dispatch_bash.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_dispatch_session_start.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_evidence_grounding.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_extract_pr.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_extract_push_ref_arrow.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_extract_push_ref_heredoc.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_extract_repo_fork_scoping.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_fail_closed_json.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_fan_out_marker.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_flag_extractor_body_file.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_forge_aware_extract_pr.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_fresh_fork.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_githooks_pre_commit_protected_branch.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_githooks_pre_push_protected_branch.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_glossary_asides.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_glossary_lookup.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_handover_clone_prompt.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_heredoc_bypass_shapes.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_hook_drift.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_hook_exec_bits.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_hook_substitutions_bash32.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_inject_project_context.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_install_cursor_adapter.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_install_git_hooks.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_isolated_builds.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_launch_check_trend.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_leak_hooks_parser_missing.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lean_tier_reachable.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_legacy_ticket_markers.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_merge_behind.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_path_resolve.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_pr_repo_tilde_username_hardening.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_premium_hook.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_project_board.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_protected_branches.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_self_location_anchor.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_lib_self_location_cwd_anchor.sh` | 0 | 1 |
| `/bin/bash .claude/hooks/tests/test_link_custom_skills.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_maintain_docs_index.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_manage_portfolio_adapters.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_mask_quoted.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_merge_command_data.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_merge_gate_library_functions.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_merge_known_limits.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_merge_repo_flags.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_multi_repo_registry.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_normalize_json_escapes.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_nudge_control_adversarial_test.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_ops_root.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_per_project_tracker.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_portfolio_agent_routing.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_portfolio_paths.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_portfolio_paths_case_insensitive_fs.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_portfolio_paths_nested_mixed_anchors.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_portfolio_paths_windows_drive_letter.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_portfolio_resolve_into_vars.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_posix_sourced_libs.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pr_base_repo.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pr_create_gate_anchor.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pr_create_tilde_cd_target.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pr_hooks_cross_repo.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pr_quality_narrative_rule.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pre_merge_qa_offer.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pre_push_gate.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pre_push_gate_case_insensitive_fs.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_pre_push_markdownlint_batch.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_print_portfolio_primer.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_private_refs_origin_and_url_slug.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_private_refs_slug_and_runtime.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_project_config_untracked.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_proportionate_work.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_quality_regression.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_record_origin_verified_public.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_registry_parser_differential.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_release_changelog.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_release_list_removed_lines.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_release_sync.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_reporting_style.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_active_ticket_bash.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_active_ticket_git_dir.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_active_ticket_review_scratch.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_active_ticket_worktree_exemptions.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_agdr_for_arch_changes.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_agdr_for_arch_pr.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_architecture_review.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_design_review_for_ui.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_migration_ticket.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_orbit_slice_for_ticket.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_posted_review.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_skill_for_issue_create.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_require_skill_for_issue_create_gh_api.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_resolution_cache.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_resolve_ops_root_pin.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_reviewer_scratch_clone_section.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_run_configured_pre_push_checks.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_session_isolation_helper_required.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_session_isolation_regression.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_settings_git_allowlist.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_settings_wrappers_silent_noop.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_single_closes_per_pr.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_skill_invocability_gates.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_split_portfolio_v2_migration.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_split_tracker_hosts.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_start_ticket_step5.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_status_briefing.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_subpack_extraction.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_sync_codex_adapter.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_sync_cursor_adapter.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_sync_cursor_adapter_hygiene.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_sync_type_whitelisted.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_ticket_marker_readers.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_ticket_template_resolution.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_token_efficiency_wave1.sh` | 0 | 1 |
| `/bin/bash .claude/hooks/tests/test_token_efficiency_wave2.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_aware_hooks.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_config_scope.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_create.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_error_diagnostics.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_fetch_status.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_issues_detection.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_list.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_pr_merge.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_review_submit.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_tracker_zsh_self_location.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_ui_paths_exclude.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_update_chain.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_update_codex_adapter_reconcile.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_update_from_dev.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_v54_migration.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_branch_name_handover.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_branch_name_heredoc.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_branch_name_pushref.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_commit_format_heredoc.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_issue_structure.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_pr_create_external.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_pr_create_head.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_pr_create_structural_parse.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_pr_create_upstream.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_pr_required_sections.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_validate_rex_review_body.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_verify_commit_refs_cwd.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_verify_commit_refs_upstream.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_warn_bootstrap_scope.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_warn_isolated_build_risk.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_warn_review_marker_write.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_warn_stale_review_markers.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_warn_unqualified_review_marker.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_workspace_tracker_resolution.sh` | 1 | 0 |
| `/bin/bash .claude/hooks/tests/test_writing_standard.sh` | 1 | 0 |

</details>

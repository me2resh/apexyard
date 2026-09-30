# AgDR-0199: Require reviewed snapshots in CI and scan all hook libraries

> In the context of hook regression tests, I decided to fetch the reviewed PR ref into a temporary CI repository and scan every hook library for process substitution. This keeps fail-before proofs active and prevents the static check from drifting.

## Context

The squash merge removed three reviewed commits from the branch history. Local tests skipped their fail-before proofs when the commits were absent. The POSIX static check listed one library while hooks sourced other libraries in POSIX mode.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Commit old hooks as fixtures | No CI fetch | Duplicates security controls in the repository |
| Fetch the reviewed PR ref and verify each commit | Uses the reviewed snapshots | CI needs the PR ref |
| Maintain a library allowlist | Limits the scan | The list can drift |
| Scan all hook libraries | Covers every sourced library | Checks some libraries that POSIX hooks do not source |

## Decision

CI fetches the reviewed PR ref into a temporary repository. The must-block test archives each pinned commit from its own temporary clone. CI fails if any snapshot is missing. Local runs keep visible skip warnings. The static test scans all hook libraries. The three libraries with process substitution use here-doc input for their loops.

The three snapshot commits are pinned by full 40-character SHAs in the workflow and in the must-block test. After the fetch, CI runs `git cat-file -e` on each SHA. A missing object fails the job with a clear message. See AgDR-0207.

## Consequences

- CI depends on the reviewed PR ref remaining fetchable.
- A short SHA can no longer resolve to the wrong commit as history grows.
- A missing snapshot commit fails CI before the hook suite runs.
- The static check covers future hook-library additions without a list update.
- The loop changes keep variables and early returns in the current shell.

## Artifacts

- `.github/workflows/tests.yml`
- `.claude/hooks/tests/test_ci_snapshot_proofs.sh`
- `.claude/hooks/tests/test_posix_sourced_libs.sh`
- AgDR-0207

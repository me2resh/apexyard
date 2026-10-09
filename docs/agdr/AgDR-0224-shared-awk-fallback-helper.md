# AgDR-0224: Share the awk fallback and continuation join

> Share one awk helper and one continuation join to preserve gate behavior, accepting an explicit caller contract.

## Context

Issue #1587 replaces seven awk sites with a shared helper. Rex requested changes on PR #1611 after finding two regressions.

An `exit` inside the opaque classifier's END block skipped the helper's later END block. Its fallback missed split-line merges.

Lazy loading also allowed missing helper files to disable merge and write detection. AgDR-0169 requires required gate dependencies to fail closed.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Keep seven copies | Independent implementations | Repeats marker handling and fallback logic |
| Use per-site sentinels | Each site owns its marker | Repeats contracts and verification |
| Share one helper and continuation join | Centralizes completion verification | Requires strict caller and fallback contracts |

## Decision

Use `_lib-awk-fallback.sh` for one awk execution helper and one continuation join.

The helper appends a fixed 0x1c byte to input and output. The output byte is a completion sentinel.
Command substitution strips trailing newlines. The sentinel preserves those newlines until the helper removes only the final output byte.
Raw sentinel bytes in input pass through unchanged. The opaque classifier treats input record separators as opaque.

Caller programs must reach the helper's END block. They must not use `exit` in END or skip consuming the appended input byte.
Each fallback must be at least as strict as its awk path. The #1611 finding requires these contracts.
The opaque classifier's fallback always answers opaque because it cannot safely exclude split-line phrases or malformed quotes.

The extraction and write-detection libraries load the helper eagerly. Merge gates list its functions in `_require_lib` checks.
Ticket gates and PR-create validation verify the same functions before scanning. Missing dependencies block with exit 2, consistent with AgDR-0169.

`dispatch-bash.sh` retains the `broad-space` join to preserve routing for quoted, commented, and split command words.
`validate-pr-create.sh` retains that mode to detect `gh pr\<newline>create`. Removing the pair could hide the create verb.
`_has_opaque_merge_wrapper` retains the caller's locale. Other scanners retain their existing C locale.

## Consequences

- Shared completion verification discards incomplete output and invokes the caller's fallback.
- Classifier failure can block additional commands rather than permit an uncertain merge.
- Required helper loss blocks gate evaluation rather than silently disabling detection.
- Hooks continue to use bash 3.2 and BSD-compatible tools.

## Artifacts

- Issue: #1587
- PR and Rex findings: #1611
- Dependency policy: [AgDR-0169](AgDR-0169-dispatcher-fail-closed-merge-gates.md)
- Regression tests: `test_awk_fallback.sh`, `test_awk_fallback_missing.sh`, and `test_block_unreviewed_merge.sh`

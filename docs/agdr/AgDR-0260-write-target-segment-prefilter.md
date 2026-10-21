# AgDR-0260: Filter write-target segments before extraction

> For #1832, I chose a shared candidate filter to reduce segment work, accepting one additional grep per extraction loop.

Recorded: 2026-10-21T01:25:13Z.

## Context

Issue me2resh/apexyard#1832 specifies a performance change with identical detection and extraction results.
Quoted heredoc prose creates many segments that cannot contribute write targets.
AgDR-0113 requires these bodies to remain visible because a shell can execute them.

## Options Considered

| Option | Benefit | Cost |
|--------|---------|------|
| Extract every segment | Preserves the current implementation | Repeats external processes for prose |
| Filter with shared trigger expressions | Avoids extraction for irrelevant segments | Requires equivalence tests and an error fallback |
| Remove heredoc bodies | Reduces segment count | Violates AgDR-0113 and can hide writes |

## Decision

Use one numbered grep over both aligned segment views because existing trigger expressions identify every candidate.
Share those expressions with the existing extractors and matchers.
Retain the original segment walk when grep fails or the views have different lengths.
Do not add a production setting that disables the filter.

## Consequences

The extractors still decide which targets and unknown writes exist.
The filter leaves heredoc bodies and whole-command checks intact.
Tests compare stdout bytes and exit status against the full walk in disposable copies.
The timing test uses system awk and a one-line control to identify slow machines.
Disposable fixtures constrain root discovery and replace their home scratch path within the worktree.

## Artifacts

- Issue me2resh/apexyard#1832.
- `.claude/hooks/_lib-detect-bash-write.sh`.
- `.claude/hooks/tests/test_detect_bash_write_prefilter.sh`.
- `.claude/hooks/tests/test_detect_bash_write_prefilter_timing.sh`.

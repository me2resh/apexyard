# Merge-Gate Repo Resolution Precedence

> In the context of multi-repo merge gates evaluating sanctioned `/approve-merge` wrapper commands, facing a fail-open bug where a leading `cd` could make architecture and design gates inspect the wrong repository, I decided to centralize merge-target resolution with explicit command targets outranking cd-target heuristics and to fail closed when the target or diff cannot be resolved, to achieve consistent gating of the actual PR being merged, accepting stricter blocking when the operator supplies unexpanded variables or forge state is temporarily unavailable.

## Context

- Ticket: [me2resh/apexyard#1151](https://github.com/me2resh/apexyard/issues/1151)
- PR: [me2resh/apexyard#1155](https://github.com/me2resh/apexyard/pull/1155)
- The sanctioned merge path can call `tracker_pr_merge "<owner/repo>" "<pr>" ...` from a shell command that begins with `cd <ops-fork> && ...`; architecture and UI gates previously let that `cd` target outrank the wrapper's explicit positional repo argument.
- The four merge gates had drifted: approval and red-CI gates resolved the wrapper target correctly, while architecture and UI gates could query a same-number PR in the ops fork and then silently allow the merge if the wrong diff had no gated files.
- These hooks are control gates under AgDR-0104's fail-closed posture. An unexpanded `$PR_HOST_REPO`, missing forge auth, network failure, or unresolvable PR diff means the gate cannot evaluate the precondition it exists to enforce.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Patch only `require-architecture-review.sh` and `require-design-review-for-ui.sh` locally | Smallest immediate diff; directly addresses the two failing gates from the report | Preserves resolver drift across the four merge gates; future wrapper or forge shapes can reintroduce inconsistent answers; duplicates precedence logic |
| Centralize a shared `resolve_merge_repo` in `_lib-extract-pr.sh` and route all merge gates through it | One precedence contract; all gates evaluate the same PR; regression tests can exercise the resolver once plus each caller; matches the existing shared-parser direction in `_lib-extract-pr.sh` | Wider hook surface touched; existing hooks must adapt to the shared resolver contract |
| Precedence: `cd` target before wrapper positional repo | Preserves the recovery behavior added for no-`--repo` split-portfolio merges | Keeps the reported bug: a shell working-directory heuristic can override the repo explicitly named in the command being evaluated |
| Precedence: explicit command target before cd-target origin before ambient fallback | Matches operator intent and CLI semantics; keeps `cd` recovery only for commands that do not name a repo; avoids ambient checkout state unless no stronger signal exists | Requires distinguishing explicit extraction branches from ambient fallback instead of blindly promoting the old `extract_repo_from_command` call |
| Keep empty/unresolvable diff as no-op | Avoids blocking during transient forge failures; reduces false positives for non-gated PRs | Fails open exactly when the gate cannot know whether gated files exist; contradicts the hooks' control classification |
| Fail closed on unexpanded variables or unresolvable diffs | Maintains the gate's trust contract; makes ambiguous merge commands visible and retryable; prevents silent bypass through `$PR_HOST_REPO` or forge failures | Operators must rerun with literal repo/PR values or fix forge auth/connectivity before merging |

## Decision

Chosen: **central shared resolver with explicit-over-heuristic precedence and fail-closed evaluation failures**, because merge gates are only meaningful if every gate binds to the same live PR and blocks when it cannot determine the PR's repository or changed files.

The resolver precedence is:

1. Explicit CLI repo target: `--repo` / `-R`.
2. Explicit forge API path target: `repos/<owner>/<repo>/pulls/<n>/merge` or forge equivalent.
3. Explicit wrapper positional target: `tracker_pr_merge <owner/repo> <pr> ...`.
4. Leading `cd` target's git origin, used as a heuristic only when the command itself does not name a repository.
5. Ambient fallback, used last because it is the weakest signal.

The architecture and UI gates should also reject merge commands containing unexpanded repo or PR variables, and should block when `gh pr diff` / equivalent diff resolution fails or returns no evaluable file list for a merge command.

## Consequences

- `block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`, `require-architecture-review.sh`, and `require-design-review-for-ui.sh` share one repo-resolution contract instead of carrying hook-local precedence variants.
- The reported `cd <ops-fork> && tracker_pr_merge "managed/repo" "42" ...` shape evaluates `managed/repo#42`, not `ops-fork#42`.
- The `cd` recovery behavior remains available for no-explicit-repo split-portfolio commands, but it can no longer outrank a repo named in the command under review.
- Failures to expand `$PR_HOST_REPO` / `$PR_NUMBER`, authenticate to the forge, or retrieve the PR diff become visible merge blocks rather than silent design or architecture gate no-ops.
- Some transient failures now require operator remediation and retry, but the direction of failure matches the hook headers and AgDR-0104's control-gate posture.

## Artifacts

- Ticket: [me2resh/apexyard#1151](https://github.com/me2resh/apexyard/issues/1151)
- PR: [me2resh/apexyard#1155](https://github.com/me2resh/apexyard/pull/1155)
- Implementation anchor: `.claude/hooks/_lib-extract-pr.sh` centralizes `resolve_merge_repo`.
- Gate callers: `.claude/hooks/block-unreviewed-merge.sh`, `.claude/hooks/block-merge-on-red-ci.sh`, `.claude/hooks/require-architecture-review.sh`, `.claude/hooks/require-design-review-for-ui.sh`.
- Regression coverage: `.claude/hooks/tests/test_extract_pr.sh`, `.claude/hooks/tests/test_forge_aware_extract_pr.sh`, `.claude/hooks/tests/test_require_architecture_review.sh`, `.claude/hooks/tests/test_require_design_review_for_ui.sh`, `.claude/hooks/tests/test_block_unreviewed_merge.sh`, `.claude/hooks/tests/test_block_merge_on_red_ci.sh`.

# Close changelog issues only from the PR body via gh, and list lines a release removes from main

> For issue #1490, facing release tooling that closed issues from a title scope alone (and later from the squash commit body, which is not the PR description under `COMMIT_MESSAGES`) and that could delete main-only content without warning, I decided to require a closing keyword in the **real PR body fetched via `gh pr view`** before emitting `Closes #N`, with a scoped-title fallback and warning when gh fails, and to list every line the release tip removes from main before the PR opens — including removed `---` / `-- …` content lines — to stop wrong closes, silent drops of real closes, and silent main deletions.

## Context

Two faults from the v5.7.0 cut (#1426 items 3 and 4), plus a review finding on the first #1490 fix.

1. `bin/release-changelog.sh` emitted `Closes #N` from a same-repo conventional-commit scope in the subject. A PR titled `feat(#N)` with body `Refs #N` still produced a close line. That nearly closed partially fixed issues.
2. A release cut from `dev` can drop lines that still exist on `main`. The v5.6.3 sync removed contributor rows from `README.md` on `dev`. The v5.7.0 release then removed them from `main`. #1393 tracked the fix.
3. Reading the squash commit body (`git log %b`) is wrong for this repo: `squash_merge_commit_message=COMMIT_MESSAGES`, so the squash body holds the branch's commit messages, not the PR description. On `v5.7.0..dev`, that under-counted closes (e.g. dropped #1492, #1480, #1478) because PR bodies like "Closes #1492" never appear in `%b`.
4. Filtering every removed diff line that starts with `--` hid deleted `---` (YAML / markdown rules) and `-- title` content lines.

The v5.7.0 cut nearly closed #1418, #1382, and #1403, which were only partly fixed. This change extends #1076. #1076 required a same-repo conventional-commit scope before any close. This change also requires a closing keyword in the real PR body when that body is readable.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Keep scope-only closes. Add a docs warning only for main deletions. | Smallest code change. | Repeats both live faults. |
| B. Require a GitHub closing keyword in the **squash commit body** for the scoped number. Add `bin/release-list-removed-lines.sh` and a `/release` stop-and-ask step. | Works offline from git. Surfaces deletions. | Wrong body under `COMMIT_MESSAGES` — drops real closes. |
| C. Require a closing keyword in the **real PR body** via `gh pr view` for subjects ending in `(#<PR>)`. On gh failure, fall back to scoped-title close and warn. List removed lines; skip only the `--- a/...` file header after `diff --git`. | Matches GitHub close semantics and this repo's squash setting. Never silently drops a close on fetch failure. Keeps content `---` / `--` lines visible. | Needs network on the release path (already online — `/release` opens the PR with gh). |

## Decision

Chosen: **C** (supersedes the first cut of B that read `%b`).

1. A `- Closes #N` bullet needs a same-repo scope in the subject **and** a closing keyword for `#N` in the PR body returned by `$RELEASE_GH pr view <PR> --repo <repo> --json body --jq .body` (`RELEASE_GH` defaults to `gh`; tests inject a stub). `Refs #N` does not close.
2. If that fetch fails for a PR, keep the pre-#1490 / `dev` behaviour for that commit (scoped title closes) and print a warning naming the PR — never silently drop a close because of a fetch failure.
3. Unscoped, cross-repo, and revert commits still emit no close line.
4. `/release` runs `bin/release-list-removed-lines.sh` on `upstream/main..$COMPARE_REF`. A non-empty listing stops and asks before the release continues. The helper skips only the per-file `--- a/...` header after each `diff --git` line, not content lines that start with `--` / `---`.

### Rate-limit cost, errors, and timeout (#1506)

Each scoped commit whose subject ends in `(#<PR>)` costs one `gh pr view` API call. A release with N such commits makes N calls.

A rate-limit error from gh is a failed read. The script falls back to a scoped-title close and prints a warning that names the PR. It does not abort the release cut.

Each `gh pr view` call is bounded by `PR_LOOKUP_TIMEOUT` (default 10 seconds). The wrapper prefers GNU `timeout`, then macOS `gtimeout`. A timeout is a failed read with the same warning and scoped-title fallback. If neither timeout binary is on PATH, the call is unbounded and a one-time stderr warning is printed.

## Consequences

- Partially fixed issues referenced only with `Refs #N` in the PR body stay open across a release cut.
- Real PR-body closes (e.g. `Closes #1492` on PR #1493) appear even when the squash commit body has no closing keyword.
- A brief forge outage, rate limit, or timeout warns and may over-close from a scoped title rather than under-close.
- Operators see every line the release deletes from `main` before the PR opens, including removed front-matter fences and `-- title` lines.
- The next release cut is the live test for the removed-lines step and the gh-backed close check.

## Artifacts

- `bin/release-changelog.sh`
- `bin/release-list-removed-lines.sh`
- `.claude/skills/release/SKILL.md`
- `.claude/hooks/tests/test_release_changelog.sh`
- `.claude/hooks/tests/test_release_list_removed_lines.sh`
- Issue #1490
- Issue #1506 (rate-limit cost, timeout, related-issue citations)
- Related: #1076 (prefer missing close), #1393 (contributor-row restore), v5.7.0 near-misses #1418 / #1382 / #1403

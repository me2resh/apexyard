# Close changelog issues only from the PR body, and list lines a release removes from main

> For issue #1490, facing release tooling that closed issues from a title scope alone and that could delete main-only content without warning, I decided to require a body closing keyword before emitting `Closes #N` and to list every line the release tip removes from main before the PR opens, to stop wrong closes and silent main deletions, accepting that a scoped title with only `Refs #N` no longer produces a close line.

## Context

Two faults from the v5.7.0 cut (#1426 items 3 and 4).

1. `bin/release-changelog.sh` emitted `Closes #N` from a same-repo conventional-commit scope in the subject. A PR titled `feat(#N)` with body `Refs #N` still produced a close line. That nearly closed partially fixed issues.
2. A release cut from `dev` can drop lines that still exist on `main`. The v5.6.3 sync removed contributor rows from `README.md` on `dev`. The v5.7.0 release then removed them from `main`.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A. Keep scope-only closes. Add a docs warning only for main deletions. | Smallest code change. | Repeats both live faults. |
| B. Require a GitHub closing keyword in the commit body for the scoped number. Add `bin/release-list-removed-lines.sh` and a `/release` stop-and-ask step. | Matches GitHub close semantics. Works offline from git. Surfaces every deleted line. | Scoped titles with only `Refs #N` stop closing. Operators must confirm deletions. |
| C. Reintroduce `gh pr view` body lookup for closes. Diff `main` only in docs. | Uses live PR bodies. | Needs network. #1076 removed that lookup because wrong closes were worse than missing ones. |

## Decision

Chosen: **B**.

1. A `- Closes #N` bullet needs both a same-repo scope in the subject and a closing keyword for `#N` in the commit body (`Closes`, `Fixes`, or `Resolves`, with tense variants). `Refs #N` does not close.
2. Unscoped, cross-repo, and revert commits still emit no close line.
3. `/release` runs `bin/release-list-removed-lines.sh` on `upstream/main..$COMPARE_REF`. A non-empty listing stops and asks before the release continues.

## Consequences

- Partially fixed issues referenced only with `Refs #N` stay open across a release cut.
- Operators see every line the release deletes from `main` before the PR opens.
- The next release cut is the live test for the removed-lines step.

## Artifacts

- `bin/release-changelog.sh`
- `bin/release-list-removed-lines.sh`
- `.claude/skills/release/SKILL.md`
- `.claude/hooks/tests/test_release_changelog.sh`
- `.claude/hooks/tests/test_release_list_removed_lines.sh`
- Issue #1490

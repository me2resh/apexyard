---
id: AgDR-0178
timestamp: 2026-09-28T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: patterns
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Carry a Rex approval across a clean base merge, and skip a refresh when nothing overlaps

> In the context of the behind-base merge flow AgDR-0170 added, facing a
> refresh cost that repeats for every open PR in a queue even when the
> refresh finds nothing, I decided to add two narrow, fail-closed
> shortcuts: carry the Rex approval forward when the refresh is a verified
> clean replay, and skip the refresh entirely when the base's new commits
> touch none of the PR's files or a configurable shared set. I accept one
> extra local git check and one extra forge read per merge attempt, in
> exchange for cutting most refreshes in a queue to zero.

## Context

AgDR-0170 (apexyard#1386) added a stop in `/approve-merge` step 3a: before
merging, the skill checks whether the PR's head is behind its base branch
and refuses to proceed if so. The fix was correct and is unchanged by this
record. Running it in a real queue exposed its cost (apexyard#1437): each
refresh needs an updated branch, a fresh CI run, sometimes a fork CI
approval, and a full Rex re-review of a merge commit that no human wrote.
Merging PR A makes every other open PR behind again, so the cost repeats
once per PR in the queue. A session with six PRs paid roughly ten minutes
per refresh, all six were clean base merges, and none found a problem.

Two facts made the six refreshes avoidable in hindsight:

- Every refresh was a plain `git merge` of the base into the PR branch,
  with no conflict and no hand edit. The merge commit's tree is fully
  determined by its two parents — nothing a review could have caught that
  the parents themselves did not already carry.
- None of the base branch's new commits touched a file the PR itself
  changed, or a file enough hooks depend on that an unrelated PR could
  still break. The refresh bought no protection those six times.

Both facts are mechanically checkable. Neither one is safe to assume —
only to verify.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Leave the behind-base stop as-is; accept the repeated cost | No new logic, no new failure mode to reason about | The cost AgDR-0170 itself flagged as a real quarterly if a queue forms; a fully mechanical case (no conflict, no overlap) pays the same price as a genuine one |
| Trust `mergeStateStatus` or GitHub's own "up to date" flag to skip the refresh | Zero extra API calls | This is the exact field AgDR-0170 already showed lies on this repo's own ruleset — reusing it here would reopen the bug that record fixed |
| Carry the Rex marker forward whenever the SHA changed and the PR is still "behind" in the same direction (no structural check) | Simplest code | Cannot tell a clean base merge from a rebase, an amend, or a hand-resolved conflict — exactly the case a stale marker exists to block |
| Carry the Rex approval forward only when the new HEAD is a two-parent merge whose first parent is the approved SHA and `git show --remerge-diff` is empty (chosen) | Verifies the actual git object, not a claim about it; fails closed on every ambiguous shape (missing object, failed fetch, non-merge commit, octopus merge, non-empty remerge-diff) | Needs the merge commit's objects available locally; a shallow or partial clone can return `unknown` more often than a full one |
| Skip the refresh whenever the PR "looks small" (few files changed) | Cheap heuristic | Files changed and files affected are different things; a one-file PR can still be broken by an unrelated one-file base change to a shared library |
| Skip the refresh only when the base's new commits, since the merge base, touch none of the PR's own files and none of a configurable shared-file set (chosen) | Directly tests the actual overlap condition that makes a refresh matter; the shared set covers hooks and config a change elsewhere can still break; fails closed on a truncated compare (300+ files), an API failure, or an unknown result | Requires two extra forge reads (PR's own file list, base's file list since merge base); a shared-file pattern an adopter forgets to add is a silent gap until the next incident names it |

## Decision

Chosen: **both shortcuts, each fail-closed, each additive to the AgDR-0170
flow rather than a replacement for it.**

`rex_approval_carries_over` (`_lib-merge-behind.sh`) accepts the existing
Rex marker for a new HEAD only when every one of these holds, verified
against the actual git objects:

- the new HEAD has exactly two parents (a genuine merge commit, not a
  rebase/amend and not an octopus merge),
- the first parent is exactly the SHA the marker names,
- `git show --format='' --remerge-diff <new HEAD>` prints nothing (git's
  own re-run of the merge matches the recorded tree exactly — no conflict
  fix, no hand edit).

Any object the check cannot resolve locally — including after a
best-effort fetch — returns `unknown`, never `true`. A non-merge commit or
an octopus merge returns `false`. A first parent that does not match the
marker returns `false`. A non-empty remerge-diff returns `false`. Only the
exact clean-replay shape returns `true`. `block-unreviewed-merge.sh` calls
this once for the Rex marker and once for the CEO marker — each checked
independently, since either marker can be the stale one. No agent writes a
marker for this; the gate decides on its own, from state a local file
write cannot fabricate.

`merge_refresh_required` (`_lib-merge-behind.sh`) decides whether
`/approve-merge` step 3a needs the refresh at all. It compares the base
branch's files touched since the merge-base commit against the PR's own
file list and against `merge.shared_file_patterns`
(`.claude/project-config.defaults.json`, default: `.claude/hooks/_lib-*.sh`,
`.claude/settings.json`, `.claude/project-config.defaults.json`,
`bin/run-pre-push-checks.sh`, `.githooks/*`, `.github/workflows/*`). It
returns `required` — never `skippable` — on a failed `gh api` call, an
empty or missing argument, or a compare response at or above the 300-file
truncation point on either side. `skippable` only when every check
resolved and none of them found an overlap.

Neither shortcut removes the underlying stop. A PR whose refresh is
`required`, or whose HEAD shape returns anything other than `true`, gets
exactly the AgDR-0170 behaviour: stop, ask the human approver to update
the branch, wait for green CI, get Rex to look again.

## Consequences

- A queue of N ready PRs, all clean base merges with no file overlap,
  needs zero refresh cycles instead of up to N-1. Rex's time goes to
  reviewing real changes.
- `/approve-merge` makes one additional forge read (the PR's own file
  list) on a behind-base PR before deciding whether the refresh is
  needed, and `rex_approval_carries_over` makes one local git check (plus
  a best-effort fetch when an object is missing) whenever a marker's SHA
  no longer matches HEAD.
- The shared-file set is a hand-maintained list. An adopter's hook or
  config file that lives outside the default patterns and outside the
  PR's own file list is a real gap: a base-only change to it would not
  force a refresh. This is named, not hidden — adopters extend
  `merge.shared_file_patterns` for files their own fork's hooks depend on.
- A shallow or partial local clone can make `rex_approval_carries_over`
  answer `unknown` more often than a full clone would, since it cannot
  fetch every object a fully mirrored clone already has. `unknown` still
  falls through to the ordinary stale-marker block — never a false
  `true`.
- Neither shortcut changes `merge.require_up_to_date`'s default or
  behaviour when it is `false` — an adopter who already disabled the
  behind-base check entirely sees no new behaviour from this record.

## Artifacts

- `.claude/hooks/_lib-merge-behind.sh` — `rex_approval_carries_over`, `merge_refresh_required`, `_merge_behind_path_matches_any`
- `.claude/hooks/block-unreviewed-merge.sh` — carry-over check ahead of both the Rex-marker and CEO-marker stale-SHA blocks
- `.claude/skills/approve-merge/SKILL.md` — step 3a, the `skippable`/`required` branch
- `.claude/project-config.defaults.json` — `merge.shared_file_patterns`
- `.claude/hooks/tests/test_lib_merge_behind.sh`, `.claude/hooks/tests/test_block_unreviewed_merge.sh`
- AgDR-0170 (the behind-base stop this record narrows, not replaces)
- apexyard#1437, apexyard#1386

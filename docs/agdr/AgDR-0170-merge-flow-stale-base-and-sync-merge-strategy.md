---
id: AgDR-0170
timestamp: 2026-09-26T00:00:00Z
agent: platform-engineer
model: claude-sonnet-5
session: session_01KGvb2ba4gyT3TN8L2uMLTn
trigger: user-prompt
status: executed
category: patterns
---

<!-- Uses the controlled technical writing profile in .claude/rules/writing-standard.md. -->

# Stop a merge that is behind its base, and stop a sync merge that guesses on conflicts

> In the context of the merge flow, facing two silent-loss risks — a merge queue
> that races a stale CI result, and a `-X ours` sync merge that drops content
> a reviewer never saw — I decided to add a behind-base stop to `/approve-merge`
> and to replace `-X ours` with a plain merge plus commit-attributed conflict
> resolution in `/release-sync`, accepting one extra forge read per merge
> attempt and a wider sync-merge procedure.

## Context

Two related but separate problems surfaced against the merge flow (apexyard#1386, apexyard#1394):

- **A merge queue creates a race.** PR A merges to the base branch. PR B's
  last CI run still reflects the old base. `/approve-merge` had no check for
  this. A merge could complete on a CI result that never ran against the real
  merge result.
- **`/release-sync` step 5 used `git merge -X ours`.** The strategy resolves
  every conflict in favor of `dev`, with no check on which commit caused the
  conflict. Most conflicts come from the release squash commit duplicating
  content `dev` already has, and `-X ours` is correct there. But `main` can
  carry a commit that never touched `dev` at all — a PR merged straight to
  `main`, a hotfix, a hand-edited file. `-X ours` drops that commit's content
  too, with no warning. Sync commit `04bd8c7` (apexyard#1348) did exactly
  this: it dropped two contributor rows from `README.md` that existed only on
  `main`.

Both problems share a root cause: a merge step resolved ambiguity by picking
a side, instead of checking which commit introduced the conflicting content.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add a new blocking condition to `block-unreviewed-merge.sh` for a behind-base branch | One control, not two places to look | The hook cannot safely retry after an update — the SHA changes, so the existing Rex marker becomes invalid mid-block. A hook-level block also cannot print the multi-step recovery in a way the skill can naturally sequence |
| Check behind-base inside `/approve-merge`, before the merge runs (chosen) | The skill already reads the PR's state from the forge in step 3; adding one field and one stop is a small, sequenced addition. The skill can name the exact recovery steps and re-run itself | Skips the check entirely if an operator merges by hand, outside the skill — accepted, because the skill is the only sanctioned merge path (`pr-workflow.md`) |
| Keep `-X ours` in `/release-sync`, and just document the risk | No procedure change | Leaves the exact regression that already happened once (apexyard#1348) unfixed. Documentation does not stop a silent drop |
| Replace `-X ours` with a plain merge, attribute each conflict to the commit that caused it, and stop on any main-only-commit conflict (chosen) | Distinguishes a squash-duplicate conflict (safe to resolve toward dev) from a main-only-commit conflict (unsafe to guess). Adds a post-merge check that a main-only commit's content survived | Wider procedure: more steps, and a stop-and-ask path that a fully automated run cannot resolve alone |
| Attribute conflicts per-hunk instead of per-file | More precise — a file can mix squash-duplicate and main-only-commit hunks | Not reliably scriptable in a shell-driven skill. Per-file attribution is the granularity the skill already read; the same limitation is stated in the skill and this record |

## Decision

Chosen: **a behind-base stop inside `/approve-merge`, plus a plain-merge-first
sync strategy in `/release-sync`**, because both fixes catch a specific class
of silent loss at the step that already has the information to catch it,
without adding a new blocking condition to `block-unreviewed-merge.sh`.

`/approve-merge` now reads `mergeStateStatus` from the forge in the same call
that already reads the PR's state. When the status is `BEHIND` and
`merge.require_up_to_date` is `true` (the default), the skill stops before
touching either marker. It names four recovery steps: update the branch, wait
for green CI, get a short Rex re-review of the new head, and re-run
`/approve-merge`. `block-unreviewed-merge.sh` gets no new blocking condition.
It optionally names a behind-base branch as a likely contributing reason when
it already blocks on a missing or stale Rex marker. That note is additive
text on an existing block, not a new one.

`/release-sync` step 5 now runs a plain `git merge --no-ff`, not `-X ours`. On
a conflict, step 5a lists the commits on `main` that are not on `dev` and
touched the conflicting file. The release squash commit is resolved from the
version tag, not guessed from a title. When it is the only such commit, the
file resolves toward `dev`. When any other commit appears in that list, the
sync stops and asks, showing the diff and the commit list. Step 5c then
checks, for every main-only commit, that its patch still reverse-applies
cleanly against the sync branch. It stops before push if one does not.

## Consequences

- `/approve-merge` makes one additional forge read per invocation
  (`mergeStateStatus`, folded into the existing step-3 `gh pr view` call). No
  added latency on the common case where the PR is not behind.
- A behind-base PR now costs one extra round trip: update, wait for CI,
  re-review, re-approve. This is the intended cost — it replaces merging on a
  stale CI result.
- `/release-sync` no longer resolves any conflict blindly. A sync with a
  genuine main-only-commit conflict now requires a human answer instead of
  completing unattended. This is slower for the rare case that has one, and
  unchanged for the common case (squash-duplicate only, or no conflict).
- The post-merge check in step 5c is best-effort. A commit whose content was
  legitimately superseded by a later main commit can show as a false
  failure. The skill treats a failure as "investigate", not as an automatic
  abort, and this record states that limit rather than hiding it.
- Conflict attribution operates at file granularity, not hunk granularity. A
  file that mixes a squash-duplicate hunk with a main-only-commit hunk is
  classified as main-only-commit and routed to a human, which is the safe
  direction to round up on.
- `merge.require_up_to_date` is a new config key
  (`.claude/project-config.defaults.json` → `merge`, default `true`). An
  adopter who disables it accepts the original race condition knowingly.

## Artifacts

- `.claude/skills/approve-merge/SKILL.md` — step 3a (behind-base stop)
- `.claude/skills/release-sync/SKILL.md` — steps 5, 5a, 5c (plain merge, conflict attribution, post-merge check)
- `.claude/hooks/block-unreviewed-merge.sh` — optional behind-base note on an existing block
- `.claude/project-config.defaults.json` — `merge.require_up_to_date`
- `.claude/rules/pr-workflow.md` — "Before `gh pr merge`" checklist
- `docs/release-process.md` — updated to match
- `.claude/hooks/tests/test_release_sync.sh`, `.claude/hooks/tests/test_block_unreviewed_merge.sh`, `.claude/hooks/tests/test_config_merge_semantics.sh`
- apexyard#1386, apexyard#1394, apexyard#1348 (the incident that motivated the sync-merge change)

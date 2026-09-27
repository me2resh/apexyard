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

> In the context of the merge flow, we faced two silent-loss risks. A queue
> merge can use a stale CI result. A `-X ours` sync merge can drop content
> that no reviewer saw. I decided to add a behind-base stop to
> `/approve-merge`. I also decided to replace `-X ours` with a plain merge
> that stops and asks on every conflict. The cost is one extra forge read per
> merge attempt and a slower sync on the rare conflicting release.

## Context

Two related but separate problems surfaced against the merge flow (apexyard#1386, apexyard#1394):

- **A merge queue creates a race.** PR A merges to the base branch. PR B's
  last CI run still reflects the old base. `/approve-merge` had no check for
  this. A merge could complete on a CI result that never ran against the
  real merge result.
- **`/release-sync` step 5 used `git merge -X ours`.** The strategy resolves
  every conflict in favor of `dev`, with no check on which commit caused the
  conflict. Most conflicts come from the release squash commit duplicating
  content `dev` already has. But `main` can carry content that `dev` never
  had. One source is a commit that never reached `dev`, such as a PR merged
  straight to `main`, a hotfix, or a hand-edited file. Another source is an
  edit made on the release branch before the squash. `-X ours` drops the
  content from either source with no warning.

Sync commit `04bd8c7` (apexyard#1348) is the incident that exposed this. The
release squash commit was the only commit that touched `README.md` among the
commits on `main` and not on `dev`. A rule that trusts "the release squash
commit is the sole touching commit" would call this conflict safe and
resolve it toward `dev`. The release squash commit had added two contributor
rows directly on the release branch, before the squash. `dev` did not have
those rows at the point the release was cut. `-X ours` dropped them with no
warning. It resolves toward `dev` unconditionally, not because it ran the
"sole touching commit" check and got it wrong.

Both problems share a root cause. A merge step resolved ambiguity by picking
a side, instead of stopping to ask which side is correct.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Add a new blocking condition to `block-unreviewed-merge.sh` for a behind-base branch | One control, not two places to look | The hook cannot safely retry after an update. The SHA changes, so the existing Rex marker becomes invalid mid-block. A hook-level block also cannot print the multi-step recovery in a way the skill can naturally sequence |
| Check behind-base inside `/approve-merge`, before the merge runs (chosen) | The skill already reads the PR's state from the forge in step 3. Adding one field and one stop is a small, sequenced addition. The skill can name the exact recovery steps and re-run itself | Skips the check entirely if an operator merges by hand, outside the skill. Accepted, because the skill is the only sanctioned merge path (`pr-workflow.md`) |
| Keep `-X ours` in `/release-sync`, and just document the risk | No procedure change | Leaves the exact regression that already happened once (apexyard#1348) unfixed. Documentation does not stop a silent drop |
| Replace `-X ours` with a plain merge, and try to classify each conflict as a safe squash duplicate or an unsafe main-only commit | Automates the common case. No human answer needed on a confirmed squash duplicate | A squash-duplicate rule that trusts "sole touching commit" would have missed apexyard#1348. A confirmation step against a release trailer narrows the miss but still guesses when the trailer is absent or ambiguous. Every added classification rule is another rule that can be wrong in a way nobody notices until the next incident |
| Replace `-X ours` with a plain merge, and stop and ask on every conflict, with no automatic classification (chosen) | Removes the guessing step entirely. A rule with no exceptions cannot miss an exception. The procedure is simpler to state and to verify than a classification tree | Slower on a release with a genuine, easily-resolved conflict. Every such release now needs one human answer instead of zero |
| Attribute conflicts per-hunk instead of per-file | More precise. A file can mix content from more than one commit | Not reliably scriptable in a shell-driven skill. Per-file is the granularity the skill already reads, and the decision below asks a human for every conflict regardless of granularity |

## Decision

Chosen: **a behind-base stop inside `/approve-merge`, plus a plain merge that
stops and asks on every conflict in `/release-sync`**. Each fix catches one
class of silent loss at the step that already has the needed information.
Neither fix adds a blocking condition to `block-unreviewed-merge.sh`.

`/approve-merge` computes whether the PR is behind its base from the compare
API's `behind_by` field (`is_pr_behind_base` in the new
`_lib-merge-behind.sh`), not from `mergeStateStatus`. GitHub only reports
`mergeStateStatus=BEHIND` under a strict required-status-checks ruleset
policy. This repo's own `dev` ruleset does not set that policy. A PR behind
an unprotected base reports `BLOCKED`, `CLEAN`, or `UNKNOWN` instead. A check
reading `mergeStateStatus` alone never fires on the case it exists to catch.
The skill stops before it touches either marker in two cases. In the first
case, the check reports the PR behind. In the second case, the compare call
fails. Both cases apply when `merge.require_up_to_date` is `true`, which is
the default. A failed check is never read as "up to date". On a
behind-base PR, the skill asks the human approver to update the branch and
wait for green CI. The approver then gets a short Rex re-review of the new
head and runs `/approve-merge` again. `block-unreviewed-merge.sh` gets no
new blocking condition. When the hook already blocks on a missing or stale
Rex marker, it can name a behind-base branch as a likely reason. It uses the
same compare-API check. That note is additive text on an existing block,
not a new one. Both the skill's stop and the hook's note address the human
approver, not the agent reading the block. The recovery step pushes a
commit to the PR's own branch.

`/release-sync` step 5 now runs a plain `git merge --no-ff`, not `-X ours`,
and resolves the version tag to a commit with `^{commit}`. An annotated
tag's bare SHA names the tag object, not the commit. On a conflict, step 5a
stops and shows the user the diff and the commits on `main`, not on `dev`,
that touched the file. This holds even when the release squash commit is
the only such commit. The skill runs no classification and confirms nothing
against a release trailer. It asks a human every time a conflict occurs, and
the human decides which side, or which combination, is correct. Step 5c
then checks, for every main-only commit, that its patch still reverse-applies
cleanly against the sync branch, including a binary-file change. It stops
before push if one does not.

## Consequences

- `/approve-merge` makes one additional forge read per invocation, the
  compare API call `is_pr_behind_base` makes. No added latency on the common
  case where the PR is not behind.
- A behind-base PR now costs one extra round trip: update, wait for CI,
  re-review, re-approve. This is the intended cost. It replaces merging on a
  stale CI result.
- A failed compare-API call also stops the merge. This trades a rare false
  stop, on a network or auth hiccup, for never treating an unknown state as
  "up to date".
- `/release-sync` no longer resolves any conflict without a human answer.
  Every conflicting release now needs one answer per conflicting file. This
  includes a release that the old rule would have treated as a harmless
  squash duplicate. This is slower for that common case, and the cost is
  intended. `-X ours` skipped exactly this kind of file. apexyard#1348 shows
  that this skip is not safe to automate.
- The post-merge check in step 5c is best-effort. A commit whose content was
  legitimately superseded by a later main commit can show as a false
  failure. The skill treats a failure as "investigate", not as an automatic
  abort, and this record states that limit rather than hiding it.
- `merge.require_up_to_date` is a new config key
  (`.claude/project-config.defaults.json` → `merge`, default `true`). An
  adopter who disables it accepts the original race condition knowingly.

## Artifacts

- `.claude/skills/approve-merge/SKILL.md` — step 3a (behind-base stop, including the failed-check case)
- `.claude/skills/release-sync/SKILL.md` — steps 5, 5a, 5c (plain merge, stop-and-ask on every conflict, post-merge check)
- `.claude/hooks/block-unreviewed-merge.sh` — optional behind-base note on an existing block
- `.claude/hooks/_lib-merge-behind.sh` — `is_pr_behind_base`, the shared compare-API behind check
- `.claude/project-config.defaults.json` — `merge.require_up_to_date`
- `.claude/rules/pr-workflow.md` — "Before `gh pr merge`" checklist
- `docs/release-process.md` — updated to match
- `.claude/hooks/tests/test_release_sync.sh`, `.claude/hooks/tests/test_block_unreviewed_merge.sh`, `.claude/hooks/tests/test_config_merge_require_up_to_date.sh`, `.claude/hooks/tests/test_lib_merge_behind.sh`
- apexyard#1386, apexyard#1394, apexyard#1348 (the incident that motivated the sync-merge change)

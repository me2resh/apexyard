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
  carry content `dev` never had — from a commit that never touched `dev` at
  all (a PR merged straight to `main`, a hotfix, a hand-edited file), or from
  edits the release squash commit itself carries, made directly on the
  release branch before the squash. `-X ours` drops either case's content
  too, with no warning. Sync commit `04bd8c7` (apexyard#1348) did the second
  kind: the release squash commit added two contributor rows to `README.md`
  directly on the release branch, so `dev` did not have them at the point the
  release was cut from, and `-X ours` dropped both when it resolved the
  conflict toward `dev`.

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

`/approve-merge` computes whether the PR is behind its base from the compare
API's `behind_by` field (`is_pr_behind_base` in the new
`_lib-merge-behind.sh`), not from `mergeStateStatus`. GitHub only reports
`mergeStateStatus=BEHIND` under a strict required-status-checks ruleset
policy. This repo's own `dev` ruleset does not set that policy. A PR behind
an unprotected base reports `BLOCKED`, `CLEAN`, or `UNKNOWN` instead, so a
check reading `mergeStateStatus` alone never fires on the case it exists to
catch. When the check reports the PR behind and
`merge.require_up_to_date` is `true` (the default), the skill stops before
touching either marker. It names four recovery steps: update the branch, wait
for green CI, get a short Rex re-review of the new head, and re-run
`/approve-merge`. `block-unreviewed-merge.sh` gets no new blocking condition.
It optionally names a behind-base branch as a likely contributing reason when
it already blocks on a missing or stale Rex marker, using the same
compare-API check. That note is additive text on an existing block, not a
new one, and both approaches address the human approver — not the agent
reading the block — because the recovery step pushes a commit to the PR's
own branch.

`/release-sync` step 5 now runs a plain `git merge --no-ff`, not `-X ours`,
and resolves the version tag to a commit with `^{commit}` (an annotated tag's
bare SHA names the tag object, not the commit). On a conflict, step 5a lists
the commits on `main` that are not on `dev` and touched the conflicting file.
When the release squash commit is the only such commit, the file resolves
toward `dev` only after confirming, against the release commit's
`Released-From` trailer, that it changed nothing in that file relative to the
exact `dev` commit the release was cut from — a plain squash-only match is
not enough on its own, because the release branch can carry its own edits
(this is the #1348 shape). When that confirmation fails, or any other commit
appears in the touching list, the sync stops and asks, showing the diff and
the commit list. Step 5c then checks, for every main-only commit, that its
patch still reverse-applies cleanly against the sync branch, including a
binary-file change. It stops before push if one does not.

## Consequences

- `/approve-merge` makes one additional forge read per invocation (the
  compare API call `is_pr_behind_base` makes). No added latency on the
  common case where the PR is not behind.
- A behind-base PR now costs one extra round trip: update, wait for CI,
  re-review, re-approve. This is the intended cost — it replaces merging on a
  stale CI result.
- `/release-sync` no longer resolves any conflict blindly. A sync with a
  genuine main-only-commit conflict, or a squash-duplicate candidate whose
  `Released-From`-anchored diff is non-empty or whose trailer is missing,
  now requires a human answer instead of completing unattended. This is
  slower for the rare case that has one, and unchanged for the common case
  (a confirmed squash duplicate, or no conflict). A release tagged before
  AgDR-0094 introduced the `Released-From` trailer has no trailer to
  confirm against, so every squash-duplicate candidate on such a release
  routes to a human — the safe default when the record cannot confirm
  equivalence.
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
- `.claude/hooks/_lib-merge-behind.sh` — `is_pr_behind_base`, the shared compare-API behind check
- `.claude/project-config.defaults.json` — `merge.require_up_to_date`
- `.claude/rules/pr-workflow.md` — "Before `gh pr merge`" checklist
- `docs/release-process.md` — updated to match
- `.claude/hooks/tests/test_release_sync.sh`, `.claude/hooks/tests/test_block_unreviewed_merge.sh`, `.claude/hooks/tests/test_config_merge_require_up_to_date.sh`, `.claude/hooks/tests/test_lib_merge_behind.sh`
- apexyard#1386, apexyard#1394, apexyard#1348 (the incident that motivated the sync-merge change)

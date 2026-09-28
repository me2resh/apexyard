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

# Carry a Rex AND CEO approval across a clean base merge, and skip a refresh when nothing overlaps

> In the context of the behind-base merge flow AgDR-0170 added, facing a
> refresh cost that repeats for every open PR in a queue even when the
> refresh finds nothing, I decided to add two narrow, fail-closed
> shortcuts: carry BOTH the Rex approval and the CEO approval forward when
> the refresh is a forge-verified clean replay, and skip the refresh
> entirely when the base's new commits touch none of the PR's files or a
> configurable shared set. Carrying the CEO marker forward is my own
> decision, made 2026-09-28, not a default the tooling picked on its own —
> see "CEO decision" below. I accept one extra local git check, three
> extra forge reads, and a narrower "one authorization moment" rule in
> `.claude/rules/pr-workflow.md`, in exchange for cutting most refreshes in
> a queue to zero.

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

**Round-2 revision (2026-09-28).** Both Rex and Hakim reviewed the first
version of this change and requested changes before merge. Rex found a
critical bypass: the first version of `rex_approval_carries_over` checked
only that the merge's first parent equalled the approved SHA — it never
checked the SECOND parent at all. An attacker (or a bug) could set the
second parent to any commit, including one that shares history with the
approved SHA but is not the real base branch, and the check would still
answer `true`. Hakim separately flagged that every check in the function
trusted LOCAL git state — a locally forged or replaced commit object could
fool it — and that parsing `git show --remerge-diff` text is a weaker
signal than comparing trees directly. Both findings, plus a rename-handling
gap and an "unknown reads as safe" gap in `merge_refresh_required`, are
fixed in this revision. See "Decision" below for the corrected algorithm.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Leave the behind-base stop as-is; accept the repeated cost | No new logic, no new failure mode to reason about | The cost AgDR-0170 itself flagged as a real quarterly if a queue forms; a fully mechanical case (no conflict, no overlap) pays the same price as a genuine one |
| Trust `mergeStateStatus` or GitHub's own "up to date" flag to skip the refresh | Zero extra API calls | This is the exact field AgDR-0170 already showed lies on this repo's own ruleset — reusing it here would reopen the bug that record fixed |
| Carry the Rex marker forward whenever the SHA changed and the PR is still "behind" in the same direction (no structural check) | Simplest code | Cannot tell a clean base merge from a rebase, an amend, or a hand-resolved conflict — exactly the case a stale marker exists to block |
| Carry the Rex approval forward when the new HEAD is a two-parent merge whose first parent is the approved SHA and `git show --remerge-diff` is empty, verified only against local git state (round-1 version) | Verifies the actual git object, not a claim about it; fails closed on every ambiguous shape | Checked parent[0] only — never verified parent[1] was actually the real base, and never verified against the forge, so a locally-forged or replaced commit object could fool it. Superseded within this same record after Rex + Hakim's round-2 review — see "Round-2 revision" and "Decision" |
| Carry BOTH the Rex and CEO approval forward only when parent[0] and parent[1] and the resulting tree are ALL verified against the forge commit API, with parent[1] required to be an ancestor of the forge-resolved base tip, and the merge recomputed locally under a hardened git environment (chosen) | Fixes the round-1 bypass (parent[1] was never checked) and the round-1 local-trust gap (Hakim A1); a direct tree comparison replaces diff-text parsing | Three forge reads instead of one; needs the two parent objects and the base tip available locally (fetched on demand); a shallow or partial clone can return `unknown` more often than a full one |
| Skip the refresh whenever the PR "looks small" (few files changed) | Cheap heuristic | Files changed and files affected are different things; a one-file PR can still be broken by an unrelated one-file base change to a shared library |
| Skip the refresh only when the base's new commits, since the merge base, touch none of the PR's own files and none of a configurable shared-file set (chosen) | Directly tests the actual overlap condition that makes a refresh matter; the shared set covers hooks and config a change elsewhere can still break; fails closed on a truncated compare (300+ files), an API failure, or an unknown result | Requires two extra forge reads (PR's own file list, base's file list since merge base); a shared-file pattern an adopter forgets to add is a silent gap until the next incident names it |

## Decision

Chosen: **both shortcuts, each fail-closed, each additive to the AgDR-0170
flow rather than a replacement for it.**

`rex_approval_carries_over` (`_lib-merge-behind.sh`) accepts the existing
marker (Rex's OR the CEO's — the gate calls it once per marker) for a new
HEAD only when every one of these holds, each verified against the FORGE,
never against local git state alone:

- `<new_sha>`'s parent list AND tree come from the forge commit API
  (`GET /repos/<repo>/commits/<new_sha>`) — `<new_sha>`'s own local git
  object, if one exists in this clone at all, is never read or trusted.
- Exactly two parents (a genuine merge commit, not a rebase/amend and not
  an octopus merge).
- Parent[0] is exactly the SHA the marker names.
- Parent[1] is an ancestor of (or equal to) the base branch's CURRENT tip,
  resolved from the forge BY NAME (`GET /repos/<repo>/commits/<base_branch>`)
  — never a local ref, which a session with write access to the clone could
  set to anything. **This is the fix for Rex's critical-bypass finding**:
  the first version checked parent[0] only, so any second parent — not
  necessarily the real base — passed.
- A hardened local `git merge-tree --write-tree <parent0> <parent1>`
  (`GIT_NO_REPLACE_OBJECTS=1`, no system/global git config, no custom merge
  driver, `GIT_TERMINAL_PROMPT=0` on any fetch) reproduces the EXACT tree
  the forge reports for `<new_sha>`. **This is the fix for Hakim's
  hardening finding**: it replaces parsing `--remerge-diff` text with a
  direct tree-identity comparison, and the local recomputation is anchored
  to two forge-attested parent SHAs, not to anything read from `<new_sha>`
  itself.

`<old_sha>` and `<new_sha>` are validated as 40 lowercase hex characters
before any git or forge call. Any object or API call the check cannot
resolve — including after a best-effort fetch — returns `unknown`, never
`true`. A non-merge commit, an octopus merge, a parent[0] mismatch, a
parent[1] not on the base branch, or a merge-tree mismatch all return
`false`. Only the exact forge-verified, mechanically-reproducible shape
returns `true`. No agent writes a marker for this. The gate decides on its
own, from state a local file write cannot fabricate.

`merge_refresh_required` (`_lib-merge-behind.sh`) decides whether
`/approve-merge` step 3a needs the refresh at all. It compares the base
branch's names touched since the merge-base commit — `filename` AND
`previous_filename`, so a rename on either side still counts as touching a
path — against the PR's own names (same two fields) and against
`merge.shared_file_patterns` (`.claude/project-config.defaults.json`,
default: `.claude/hooks/_lib-*.sh`, `.claude/settings.json`,
`.claude/project-config.defaults.json`, `bin/run-pre-push-checks.sh`,
`.githooks/*`, `.github/workflows/*`). It returns `required` — never
`skippable` — on: a failed `gh api` call, an empty or missing argument, a
compare response at or above the 300-file truncation point on either side,
a missing or non-array `.files` field (jq's `length` builtin reads `null`
as `0`, which would otherwise silently misclassify an unparseable response
as "the base touched nothing" — the fix for the round-2 "unknown reads as
safe" finding), an empty `merge.shared_file_patterns`, or an empty PR file
list (every real PR touches at least one file, so an empty list reads as a
swallowed API error, not a genuine state). `skippable` only when every
check resolved and none of them found an overlap.

Neither shortcut removes the underlying stop. A PR whose refresh is
`required`, or whose HEAD shape returns anything other than `true`, gets
exactly the AgDR-0170 behaviour: stop, ask the human approver to update
the branch, wait for green CI, get Rex to look again.

`/approve-merge` step 4 (the skill, not only the gate) calls the same
`rex_approval_carries_over` function before refusing on a stale Rex
marker — the two now agree by construction. Before this round, only the
gate checked carry-over; the skill would refuse a merge the gate would
have accepted, which made the carry-over unreachable through the sanctioned
merge path.

### CEO decision: the CEO marker carries over too (2026-09-28)

The first version of this record only carried the Rex marker forward. I
decided the CEO marker carries over on the identical, forge-verified
condition, dated 2026-09-28. Reasoning: `.claude/rules/pr-workflow.md`
states the CEO marker and the merge are "one authorization moment" —
writing the marker and running the merge are a single deterministic
consequence of one explicit, per-PR approval. A forge-verified,
conflict-free base-branch replay does not introduce any content I did not
already approve; it only changes the SHA the marker points at. Refusing to
carry the CEO marker forward while carrying the Rex marker forward would
make every one of these mechanically-clean refreshes stop anyway, asking me
to re-approve a merge whose content is identical to what I already approved
— defeating the entire point of this record. This is a genuine exception to
"one authorization moment," not a redefinition of it: `.claude/rules/pr-workflow.md`
now states the exception explicitly, and it applies ONLY to the same
narrow, fail-closed condition `rex_approval_carries_over` verifies. Any
case that function cannot fully verify still requires a fresh
`/approve-merge` invocation, exactly as before this record.

## Consequences

- A queue of N ready PRs, all clean base merges with no file overlap,
  needs zero refresh cycles instead of up to N-1. Rex's time goes to
  reviewing real changes.
- `/approve-merge` makes one additional forge read (the PR's own file
  list) on a behind-base PR before deciding whether the refresh is
  needed. `rex_approval_carries_over` makes three forge reads (base tip by
  name, the head commit's parents and tree, and — implicitly, via
  `merge-base`/`merge-tree` — the two parent objects) plus a hardened
  local git computation, whenever a marker's SHA no longer matches HEAD.
  This is more forge traffic than the round-1 version, traded deliberately
  for not trusting local git state alone (Hakim A1).
- Carrying the CEO marker forward, not only Rex's, means a merge can now
  complete without a fresh human message between the original approval and
  this particular merge. This is the CEO's own accepted trade-off (see "CEO
  decision" above), bounded to the same narrow, fail-closed condition —
  it does not apply to any commit the carry-over check cannot fully verify.
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

- `.claude/hooks/_lib-merge-behind.sh` — `rex_approval_carries_over`, `merge_refresh_required`, `_merge_behind_path_matches_any`, `_rex_carry_git`, `_rex_carry_is_sha40`
- `.claude/hooks/block-unreviewed-merge.sh` — carry-over check ahead of both the Rex-marker and CEO-marker stale-SHA blocks; `BASE_REF_NAME` resolved once and shared with `print_behind_base_note`
- `.claude/skills/approve-merge/SKILL.md` — step 3a (the `skippable`/`required` branch) and step 4 (carry-over parity with the gate)
- `.claude/project-config.defaults.json` — `merge.shared_file_patterns`
- `.claude/rules/pr-workflow.md` — the "one authorization moment" exception for a forge-verified base-branch replay
- `.claude/hooks/tests/test_lib_merge_behind.sh`, `.claude/hooks/tests/test_block_unreviewed_merge.sh`
- AgDR-0170 (the behind-base stop this record narrows, not replaces)
- apexyard#1437, apexyard#1386

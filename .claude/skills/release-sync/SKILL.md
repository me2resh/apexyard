---
name: release-sync
description: Sync main back to dev after a squash-merge release — files a PR that makes the release squash commit an ancestor of dev, eliminating future merge conflict accumulation.
argument-hint: "<version, e.g. v2.0.3>"
allowed-tools: Bash, Read, Write
---

# /release-sync — Sync main→dev after a release

The sync PR body is a durable, human-facing artefact. Read
`.claude/rules/writing-standard.md`. Use the **controlled technical writing profile**: lead with the
outcome and next action, use plain concise prose, and remove empty sections.

Every squash-merge release (`dev → main`) creates a SHA divergence: the squash commit on `main` is absent from `dev`, so `dev` still carries the un-squashed equivalents as separate commits. Repeated releases accumulate the divergence until the next `dev → main` release PR becomes a conflict-heavy nightmare (v2.0.0 suffered 99 conflicts because of this). This skill closes the loop: after each release, file a `main→dev` sync PR that makes the squash commit an ancestor of `dev`, so future release PRs only see genuinely-new commits.

This skill is **framework-only** — only for the `me2resh/apexyard` framework repo. It has no meaning on managed projects, which are trunk-based and never squash-merge to a separate `main`.

## Usage

```
/release-sync v2.0.3
```

Typically invoked as the final step of `/release`, after the release tag has been pushed.

## Process

### 1. Pre-flight

Verify:

- Current repo IS the apexyard framework (origin or upstream points at `me2resh/apexyard`). Refuse otherwise.
- `<version>` argument provided and matches `v\d+\.\d+\.\d+`. Refuse if missing or malformed.
- `upstream/main` and `upstream/dev` exist (`git rev-parse --verify`). Refuse if either is absent.
- The tag `<version>` exists on `upstream/main` (`git tag -l <version>`). Warn if absent (the release may not have completed yet).

### 2. Check for divergence

```bash
git fetch upstream main dev --tags
COMMITS_ON_MAIN_NOT_ON_DEV=$(git log upstream/dev..upstream/main --oneline | wc -l | tr -d ' ')
```

- If `COMMITS_ON_MAIN_NOT_ON_DEV -eq 0`: **already in sync** — print a single-line message and exit 0 (no-op). Do NOT open a PR.
- If only `upstream/dev..upstream/main` is empty but `upstream/main..upstream/dev` is also empty: branches are identical — exit 0.
- If `COMMITS_ON_MAIN_NOT_ON_DEV -gt 0`: proceed with the sync.

### 3. Check for backwards case

```bash
COMMITS_ON_DEV_NOT_ON_MAIN=$(git log upstream/main..upstream/dev --oneline | wc -l | tr -d ' ')
```

This check is informational only — having dev ahead of main is the expected normal state (dev has new work not yet released). Proceed normally.

However, if `COMMITS_ON_MAIN_NOT_ON_DEV -eq 0` AND `COMMITS_ON_DEV_NOT_ON_MAIN -gt 0`: branches are divergence-free from the main→dev direction (main has nothing dev doesn't). Exit 0, already in sync.

### 4. Create the sync branch

```bash
git checkout -b sync/main-to-dev-after-<version> upstream/dev
```

The branch is based on `upstream/dev` (NOT `upstream/main`). This is intentional — we're merging main INTO dev, not branching from main.

> **`sync` is a whitelisted type** (apexyard#458). The `sync/` branch prefix, the `sync:` commit subject, and the `sync(#N):` PR title are all accepted by the branch / commit / PR-title validators. The branch name `sync/main-to-dev-after-vN.N.N` is also exempt from the `{type}/{TICKET-ID}-{desc}` ticket-id requirement (same narrow exception as `release/vN.N.N`) — the release being synced is the ticket. The PR title still references a live OPEN ticket via `sync(#N):` (use the release-cut ticket or a dedicated sync ticket), since `validate-pr-create.sh` checks ticket existence independent of the type.

### 5. Merge main with a plain merge (apexyard#1394)

```bash
RELEASE_SHA=$(git rev-parse "<version>^{commit}")

git merge --no-ff -m "sync: merge main into dev after <version> release

Squash-merge divergence from the <version> release PR creates phantom divergence
between main and dev. This merge makes the <version> squash commit an ancestor
of dev so future dev→main release PRs only see genuinely-new commits.

Refs #403" upstream/main
```

**Peel the tag with `^{commit}`.** The auto-tag workflow creates an
**annotated** tag (`git tag -a`). `git rev-parse "<version>"` on an annotated
tag returns the tag *object*'s SHA, not the commit it points at — a
different value from the release squash commit on `main`. The `^{commit}`
suffix peels the tag to the commit it names, regardless of tag type. Without
it, `$RELEASE_SHA` never matches any commit in step 5a's touching-commit
list, so the squash-duplicate case below never classifies correctly.

`$RELEASE_SHA` is the exact commit the version tag names — the release squash
commit on `main`. Step 5a uses it to tell a squash-duplicate conflict apart
from a conflict that touches genuinely new content.

**Why a plain merge, not `-X ours`.** `-X ours` resolves every conflicting hunk
in favour of `dev`, with no check on which commit introduced the conflicting
content on `main`. Most of the time that content is the release squash
commit's duplicate of what `dev` already carries, and dropping it is correct.
But `main` can carry content `dev` never had, from two different sources: a
commit that was never on `dev` at all (a PR merged straight to `main`, a
hand-edited file, a hotfix), or edits made directly on the release branch
before it was squashed — so the release squash commit itself is not
guaranteed to match `dev`, even when it is the only commit in the touching
list. `-X ours` drops either case's content too, silently and with no
warning. This is exactly what happened in apexyard#1348: sync commit
`04bd8c7` hit a `README.md` conflict, and the release squash commit that
caused it had added two contributor rows directly on the release branch —
content `dev` did not have at the cut point the release was made from. A
plain merge surfaces every conflict instead of resolving it blindly, so
step 5a below can tell these cases apart from a genuine squash duplicate.

If the merge completes with no conflicts, skip to step 5b.

### 5a. On conflict: attribute each file to the commit that caused it

```bash
CONFLICTS=$(git diff --name-only --diff-filter=U)
```

For each file in `$CONFLICTS`, list the commits on `main` that are not on
`dev` and touched that file:

```bash
git log upstream/dev..upstream/main --format=%H -- "<file>"
```

Compare the result against `$RELEASE_SHA` from step 5:

- **Squash-duplicate candidate.** `$RELEASE_SHA` is the ONLY commit in that
  list. This is NOT yet enough to resolve toward `dev` — the release squash
  commit can itself carry edits `dev` never had, made directly on the
  release branch before the squash merge (this is what actually happened in
  apexyard#1348: two contributor rows were added on the release branch, so
  `$RELEASE_SHA` being the sole touching commit did not mean `dev` already
  had the content). Confirm it against the release commit's own
  `Released-From` trailer — the exact `dev` SHA the release was cut from:

  ```bash
  RELEASED_FROM=$(git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly)' "$RELEASE_SHA")
  ```

  - **`$RELEASED_FROM` is non-empty AND `git diff "$RELEASED_FROM" "$RELEASE_SHA" -- "<file>"` is empty.**
    The release commit changed nothing in this file relative to the exact
    `dev` commit it was cut from — `dev`'s current content is confirmed
    equivalent. Resolve toward `dev`:

    ```bash
    git checkout --ours -- "<file>"
    git add "<file>"
    ```

    `git checkout --ours` takes the WHOLE file from `dev`'s side of the
    merge, not just the conflicting hunks — different from `-X ours`, which
    resolved every hunk in the file that way regardless of conflict. Here
    the whole-file swap is safe because the diff above already confirmed the
    two sides are equivalent for this file.

  - **Otherwise** — the trailer is missing, or the diff is non-empty. Either
    means this file cannot be confirmed safe to resolve automatically: a
    missing trailer means there is nothing to compare against, and a
    non-empty diff means the release branch changed this file relative to
    the `dev` cut point. Route it to the same stop-and-ask path as a
    main-only commit, below — do not guess.

- **Main-only commit.** Any OTHER commit appears in that list — a commit that
  exists on `main` and nowhere on `dev`. Picking either side blindly would
  lose content. **Stop and ask the user** how to resolve this file. Show:

  ```bash
  git diff upstream/dev upstream/main -- "<file>"
  git log upstream/dev..upstream/main --oneline -- "<file>"
  ```

  Do not resolve a main-only-commit file automatically. Once the user names
  the resolution, `git add` the file and continue.

Once every conflicting file is resolved, finish the merge:

```bash
git commit --no-edit
```

If any file needed a stop-and-ask, wait for the user's answer before running
this commit. Do not commit the merge with an unresolved or auto-guessed file.

### 5b. Carry forward `CHANGELOG.md` from main (apexyard#448)

`dev` should win on a squash-duplicate conflict, per step 5a — but
`CHANGELOG.md` is the one file where the opposite is true: every release
writes new entries on `main`, and `dev` should track those entries forward.
Without this step the release-notes history accumulates only on `main`, and
the next `/release` run prepends a new entry on a stale `dev` CHANGELOG and
the squash-merge silently truncates the prior releases on `main` (see
apexyard#446 / #447 for the symptom this caused for v2.2.0).

After the merge in step 5 (and any conflict resolution in step 5a), **check
whether `CHANGELOG.md` on the sync branch differs from `upstream/main`'s copy.
If yes, replace it with main's copy and commit it as a separate atomic commit
on top of the merge.**

```bash
# Compare the sync branch's CHANGELOG to main's. Use --quiet so the exit
# code is the load-bearing signal: 0 = same, 1 = different.
if ! git diff --quiet upstream/main -- CHANGELOG.md; then
  echo "Carrying forward CHANGELOG.md from main..."
  git checkout upstream/main -- CHANGELOG.md
  # Re-check: did the checkout actually change anything in the working tree?
  if ! git diff --quiet --cached -- CHANGELOG.md \
      || ! git diff --quiet -- CHANGELOG.md; then
    git add CHANGELOG.md
    git commit -m "sync: carry forward CHANGELOG.md from main after <version> release

The merge above kept dev's CHANGELOG.md, which lacks the entries
written on main during the <version> release flow. This commit restores
main's CHANGELOG so dev tracks the full release history forward.

Without this step the next /release run would prepend the new version
entry on a stale dev CHANGELOG, and the squash-merge to main would silently
truncate the prior releases — the exact pre-v2.2.0 regression captured in
apexyard#446 and root-caused in apexyard#448.

Refs #448"
  fi
fi
```

**Path-specific by design (v1).** This step is hardcoded to `CHANGELOG.md` — the one file the release flow writes on `main`. Generalising to other "main-leads" files is deferred until a second one shows up (and would warrant the YAML config knob mentioned in #448 § "Design Notes").

**Why a separate commit rather than amending the merge.** The carry-forward is a deliberate, audit-trail-visible step. Leaving it as its own commit makes the operation reviewable in the sync PR (Rex sees two commits and can sanity-check each); amending would hide the carry-forward inside the merge commit and obscure the audit trail.

**Idempotent.** Re-running `/release-sync` on an already-synced repo finds `git diff --quiet upstream/main -- CHANGELOG.md` returns 0, the `if` block is skipped, and no commit is created. The existing "already in sync" guard in step 2 still catches the all-empty case; this guard handles the narrower "code is synced but CHANGELOG drifted in a prior unfixed run" case.

**What this step does NOT do.**

- Does **not** touch any file other than `CHANGELOG.md`.
- Does **not** modify `main`'s tree — only updates the sync branch's `CHANGELOG.md` to match.
- Does **not** rewrite history — the carry-forward is a fresh commit on top of the merge commit.
- Does **not** run if `main`'s `CHANGELOG.md` equals dev's (post-merge) — the `if` guard skips the entire block.
- Does **not** preserve in-flight `CHANGELOG.md` edits on `dev`. Under the release-cut model `dev` does NOT add CHANGELOG entries between releases — only `/release` writes there — so this is the expected steady-state. If an adopter has hand-edited `CHANGELOG.md` on `dev`, the carry-forward overwrites those edits. The right shape for that case is to land the edits via the `/release` skill (or a chore PR) before invoking `/release-sync`.

### 5c. Post-merge check — every main-only commit's content must still be present (apexyard#1394)

After the merge commit exists (steps 5, 5a, and 5b) and before pushing, verify
that no main-only commit's content was lost. For every non-merge commit in
`upstream/dev..upstream/main`, check that its patch still reverse-applies
cleanly against the sync branch:

```bash
FAILED_COMMITS=""
for commit in $(git log upstream/dev..upstream/main --format=%H --no-merges); do
  if ! git apply --check --reverse <(git show --binary "$commit") >/dev/null 2>&1; then
    FAILED_COMMITS="$FAILED_COMMITS $commit"
  fi
done
```

`--binary` matters: without it, `git show` prints a text placeholder for a
binary-file change instead of a patch, and `git apply` cannot reverse-apply
a placeholder — so any commit that touched a binary file would show as a
false failure on every run, textual content included or not.

A commit's patch reverse-applying cleanly means the change it introduced on
`main` is present, unchanged, in the sync branch right now. A name in
`$FAILED_COMMITS` means that commit's content did not check out this way.

**If `FAILED_COMMITS` is non-empty, stop before pushing.** Report each failing
commit's SHA, subject, and touched files (`git show --stat <commit>`) to the
user. Do not push a sync branch that may have lost a main-only commit's
content — this check exists to catch exactly the class of silent loss
`-X ours` caused in apexyard#1348.

This check is best-effort, not a guarantee. A commit whose content was later
and legitimately superseded by a different main commit can show as a false
failure. A hunk whose original patch ended at end-of-file is also brittle to
new content placed after it in a hand-resolved file — put a manual
resolution's own new lines before the preserved block, not after, when a
commit's changes sit at the tail of the file. Treat a failure as
"investigate", not as an automatic abort.

### 6. Push and open the PR

```bash
git push upstream sync/main-to-dev-after-<version>
gh pr create \
  --repo me2resh/apexyard \
  --base dev \
  --head sync/main-to-dev-after-<version> \
  --title "sync(#403): main→dev after <version> release" \
  --body "<PR body — see template below>"
```

**PR body template:**

```markdown
## Summary

- **Syncs main→dev after the <version> release** — makes the <version> squash commit
  an ancestor of `dev` so the next `dev→main` release PR only sees genuinely-new
  commits instead of fighting the accumulated squash divergence
- **Merge strategy: plain merge, conflicts attributed by commit** — a conflict caused
  only by the release squash commit resolves toward `dev`, but only after confirming
  the release commit changed nothing in that file relative to its `Released-From`
  `dev` cut point. A conflict that also involves a main-only commit, or that fails
  that confirmation, stops and asks instead of guessing. Replaces the blind `-X ours`
  strategy that dropped main-only content with no warning (apexyard#1394).
- **`CHANGELOG.md` is carried forward separately** — the plain merge keeps dev's
  CHANGELOG, so a second commit on top of the merge restores `main`'s
  `CHANGELOG.md` verbatim. Path-specific, audit-trail-visible, idempotent. See apexyard#448.
- **Post-merge check** — every main-only commit's content is verified present
  before push (apexyard#1394); a commit that appears lost stops the sync rather
  than pushing silently.
- **No functional changes** — this is a bookkeeping merge that reconciles SHA
  divergence introduced by the squash-merge release flow; no logic is added or removed

## Background

The apexyard release flow squash-merges dev→main on every release. This creates a
divergence: main has one squash commit (SHA X); dev still has the original un-squashed
commits. A future dev→main release PR then conflicts on all the diffs that X also
touched. v2.0.0 suffered 99 conflicts because of this accumulated gap.

This PR merges main→dev with a plain merge so the squash commit becomes an ancestor
of dev. Future release PRs then only show genuinely-new commits in the diff. A plain
merge, not `-X ours`, because `main` can carry commits `dev` never had — a squash
commit isn't the only thing that can land there — and `-X ours` drops those silently
(apexyard#1348, apexyard#1394).

See [#403](https://github.com/me2resh/apexyard/issues/403) for full root-cause analysis.

## Testing

1. After merging, verify: `git log upstream/dev..upstream/main --oneline` returns empty
2. Verify ancestry, not `main..dev`'s size: `git merge-base --is-ancestor <release-squash-sha> upstream/dev` exits 0. (#1002 — `git log upstream/main..upstream/dev --oneline` does **not** shrink to "only commits newer than \<version\>"; under the release-cut squash model no individual `dev` commit is ever reachable from `main`, so that range accumulates every past release's un-squashed history and stays large — currently ~400 commits — even on a perfectly-synced repo. The merge-base check is the assertion that actually proves the sync worked.)
3. Verify CHANGELOG is in sync: `diff <(git show upstream/main:CHANGELOG.md) <(git show upstream/dev:CHANGELOG.md)` returns empty (apexyard#448)
4. Verify no main-only commit was lost: the step 5c loop reports an empty `$FAILED_COMMITS` (apexyard#1394)
5. Open a test release PR from dev → main — confirm only new work appears in the diff and the next `/release` v<next-version> prepends cleanly on top of <version>

Refs #403, #448, #1002, #1394

---

## Glossary

| Term | Definition |
|------|------------|
| Squash divergence | When a release PR is squash-merged to main, the resulting commit has a different SHA than the equivalent dev history, so dev still carries the un-squashed commits as "unsynced" |
| Squash-duplicate conflict | A merge conflict where the release squash commit is the ONLY main-only commit that touched the file, AND its content matches the `dev` commit named in its `Released-From` trailer for that file. Confirmed equivalent, so the conflict resolves toward `dev`. |
| Main-only commit | A commit that exists on `main` and nowhere on `dev` — a PR merged straight to `main`, a hand-edited file, a hotfix. A conflict that involves one stops the sync and asks, rather than guessing. |
| `sync/main-to-dev-after-<version>` | Short-lived branch used to carry the merge commit from main into dev; deleted after the PR merges |
| CHANGELOG carry-forward | Path-specific step 5b that restores `main`'s `CHANGELOG.md` on the sync branch after the merge in step 5 would otherwise keep dev's stale copy. Atomic separate commit, idempotent re-run. See apexyard#448. |
| Post-merge content check | Step 5c: for every main-only commit, verify its patch still reverse-applies cleanly against the sync branch, confirming the content survived the merge. See apexyard#1394. |
```

### 7. Stop at PR creation

Do **NOT** merge the sync PR. Rex + CEO approval applies to this PR the same as any other. The skill's job is to open the PR; the operator drives the merge gate.

**CRITICAL — merge strategy for this PR:**

> The sync PR **MUST** be merged with a **true merge (`--merge`)**, never `--squash` or `--rebase`.

The merge commit produced by step 5 above is the artefact that closes ancestry. It carries **two parents**: (1) the dev branch head, and (2) the release squash commit on main. That two-parent relationship is exactly what makes `git merge-base --is-ancestor <release-squash> dev` return true — i.e., what makes future release PRs conflict-free.

Squash-merging this sync PR collapses the two-parent merge commit into a single-parent commit. The second parent (pointing at main's release squash) is permanently discarded. Dev gets main's *content* but the release squash is NOT an ancestor of dev. The `git log upstream/dev..upstream/main` divergence check will still show commits after squash — the exact failure this skill exists to prevent.

`/approve-merge` auto-detects `sync/`-prefixed PRs and uses `--merge` automatically. If merging via the CLI directly, pass `--merge` (not `--squash`, not `--rebase`):

```bash
gh pr merge <sync-pr-number> --repo me2resh/apexyard --merge --delete-branch
```

A guard in `block-unreviewed-merge.sh` will also refuse `--squash` on a `sync/`-prefixed PR to prevent accidental regression. See `AgDR-0053`.

Print:

```
Sync PR opened: <URL>
Branch: sync/main-to-dev-after-<version> → dev
Commits on main not yet on dev: N
Next step: /code-review, then /approve-merge once Rex approves.
IMPORTANT: /approve-merge will use --merge (not --squash) automatically for this sync PR.
After merge: git log upstream/dev..upstream/main should return empty.
After merge: git merge-base --is-ancestor <release-squash-sha> upstream/dev should return true.
```

## Edge Cases

| Scenario | Behaviour |
|----------|-----------|
| Already in sync (`dev..main` is empty) | Exit 0, print "Already in sync — no PR needed." |
| Tag does not exist yet | Warn "Tag <version> not found on upstream/main — has the release PR merged and been tagged?" then abort |
| Merge produces zero diff (all conflicts resolved to identical content) | Proceed — the merge commit itself is the artefact, even if the tree is identical to dev HEAD |
| Skill invoked on a managed project | Exit 1 with error "release-sync is framework-only" |
| Version not provided | Exit 1 with usage hint |
| Code is synced but `CHANGELOG.md` drifted (prior unfixed `/release-sync` run, manual main edit, etc.) | Step 2's `git log dev..main` may be empty yet step 5b's `git diff upstream/main -- CHANGELOG.md` is not. In that case create the sync branch from `upstream/dev`, skip the merge in step 5 (nothing to merge), run only step 5b's carry-forward commit, and open the PR with the body trimmed to the CHANGELOG-only summary. The PR is still useful — it surfaces the drift to a reviewer rather than letting the next `/release` silently truncate history. |
| Dev has in-flight edits to `CHANGELOG.md` between releases (unusual) | Carry-forward overwrites them. This is a recognised trade-off — under the release-cut model `dev` only receives CHANGELOG edits via `/release`. If you genuinely need a between-release CHANGELOG edit, land it via a chore PR before running `/release-sync` so the file is identical on `main` and `dev` by the time this skill runs. |

## Rules

1. **Framework-only.** Refuse on managed projects.
2. **No auto-merge.** The PR must go through Rex + CEO approval like every other PR.
3. **Branch base is always `upstream/dev`.** Never branch from main for this operation.
4. **Plain merge, conflicts attributed by commit (apexyard#1394).** Never use `-X ours`. A conflict caused only by the release squash commit resolves toward `dev` only after its `Released-From`-anchored diff confirms the file is unchanged. A conflict involving a main-only commit, or one that fails that confirmation, stops and asks. Do not offer to resolve either case automatically.
5. **`--merge` (true merge) on PR merge.** Never `--squash` or `--rebase`. The merge commit IS the ancestry-closure artefact; destroying it defeats the skill's purpose. `/approve-merge` enforces this automatically on `sync/`-prefixed PRs; a guard in `block-unreviewed-merge.sh` refuses `--squash` on them as a mechanical backstop.
6. **No-op on already-synced repos.** Idempotent: if main has nothing dev doesn't, exit 0.
7. **Version argument is required.** The version labels the sync branch and PR body for auditability.

## Related

- `/release` — the upstream skill that creates the squash divergence; invoke `/release-sync` as its final step
- `AgDR-0007` — the release-cut branch model this skill stabilises
- `AgDR-0052` — the original design decisions for this skill
- `AgDR-0053` — the decision to use `--merge` (not `--squash`) for sync PRs, and the auto-detect + guard design
- `AgDR-0170` — the decision to replace `-X ours` with a plain merge + commit-attributed conflict resolution (apexyard#1394)
- `docs/release-process.md` — the prose runbook

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

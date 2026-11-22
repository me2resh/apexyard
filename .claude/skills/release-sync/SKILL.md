---
name: release-sync
description: Sync main back to dev after a squash-merge release. Files a PR that makes the release squash commit an ancestor of dev, eliminating future merge conflict accumulation.
argument-hint: "<version, e.g. v2.0.3>"
allowed-tools: Bash, Read, Write
---

# /release-sync: Sync main→dev after a release

The sync PR body is a durable, human-facing artefact. Read
`.claude/rules/writing-standard.md`. Use the **controlled technical writing profile**: lead with the
outcome and next action, use plain concise prose, and remove empty sections.

Every squash-merge release (`dev → main`) creates a SHA divergence.
The squash commit on `main` is absent from `dev`.
Thus, `dev` still carries the un-squashed equivalents as separate commits.
Repeated releases accumulate divergence until the next `dev → main` release PR has many conflicts.
For example, v2.0.0 had 99 conflicts.
After each release, file a `main→dev` sync PR that makes the squash commit an ancestor of `dev`.
Future release PRs then show only new commits.

This skill is **framework-only**: use it only for the `me2resh/apexyard` framework repo.
Managed projects use trunk-based development and never squash-merge to a separate `main`, so this skill does not apply.

## Usage

```
/release-sync v2.0.3
```

Typically, invoke this as the final step of `/release`, after pushing the release tag.

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

- If `COMMITS_ON_MAIN_NOT_ON_DEV -eq 0`: **already in sync**. Print a single-line message. Exit 0 (no-op). Do NOT open a PR.
- If both `upstream/dev..upstream/main` and `upstream/main..upstream/dev` are empty, the branches are identical. Exit 0.
- If `COMMITS_ON_MAIN_NOT_ON_DEV -gt 0`: proceed with the sync.

### 3. Check for backwards case

```bash
COMMITS_ON_DEV_NOT_ON_MAIN=$(git log upstream/main..upstream/dev --oneline | wc -l | tr -d ' ')
```

This check is informational only. Normally, dev is ahead of main because dev has unreleased work. Proceed normally.

However, if `COMMITS_ON_MAIN_NOT_ON_DEV -eq 0` AND `COMMITS_ON_DEV_NOT_ON_MAIN -gt 0`, main has nothing absent from dev. Exit 0, already in sync.

### 4. Create the sync branch

```bash
git checkout -b sync/main-to-dev-after-<version> upstream/dev
```

Base the branch on `upstream/dev` (NOT `upstream/main`). This operation merges main INTO dev, rather than branching from main.

> **`sync` is a whitelisted type** (apexyard#458).
> The branch, commit, and PR-title validators accept the `sync/` prefix, `sync:` subject, and `sync(#N):` title.
> The branch name `sync/main-to-dev-after-vN.N.N` is exempt from the `{type}/{TICKET-ID}-{desc}` ticket-id requirement.
> This is the same narrow exception as `release/vN.N.N`: the release to sync serves as the ticket.
> The PR title still references a live OPEN ticket via `sync(#N):`.
> Use the release-cut ticket or a dedicated sync ticket.
> `validate-pr-create.sh` checks ticket existence independently of the type.

### 5. Merge main with a plain merge (apexyard#1394)

```bash
RELEASE_SHA=$(git rev-parse "<version>^{commit}")

git merge --no-ff -m "sync: merge main into dev after <version> release

Squash-merge divergence from the <version> release PR creates phantom divergence
between main and dev. This merge makes the <version> squash commit an ancestor
of dev so future dev→main release PRs only see genuinely-new commits.

Refs #403" upstream/main
```

**Peel the tag with `^{commit}`.** The auto-tag workflow creates an **annotated** tag (`git tag -a`).
For an annotated tag, `git rev-parse "<version>"` returns the tag *object*'s SHA, rather than the target commit's SHA.
That value differs from the release squash commit on `main`.
The `^{commit}` suffix resolves the tag to its target commit, regardless of tag type.

`$RELEASE_SHA` is the exact commit the version tag names: the release squash commit on `main`.
Step 5a uses it only to label that commit in the list of commits that touched a conflicting file.
It does not determine conflict resolution. See below.

**Why a plain merge, not `-X ours`.** `-X ours` resolves every conflicting hunk in favour of `dev`.
It does not check which commit introduced the conflicting content on `main`.
Most conflicts duplicate content from the release squash commit that `dev` already carries, so discarding that content can look correct.
However, `main` can carry content that `dev` never had, from two sources:

- A commit never on `dev`: a PR merged directly to `main`, a hand-edited file, or a hotfix.
- An edit made directly on the release branch before the squash.

Thus, the release squash commit does not necessarily match `dev`, even when it alone touched a file.
`-X ours` silently discards content from either source, without warning.

This happened in apexyard#1348. Sync commit `04bd8c7` encountered a `README.md` conflict.
Only the release squash commit appeared in the file's touching list.
A rule that trusts "sole touching commit" would classify the conflict as a safe duplicate.
However, that squash commit had added two contributor rows directly on the release branch, before the squash.
`dev` never had those rows. `-X ours` discarded them without warning.
A rule that distinguishes safe duplicates from unsafe content must be correct every time. #1348 shows that it is not.
This skill does not attempt that distinction.
A plain merge exposes every conflict. Step 5a stops on every conflict instead of guessing.

If the merge completes without conflicts, skip to step 5b.

### 5a. On conflict: stop, list, and ask: never resolve automatically

```bash
CONFLICTS=$(git diff --name-only --diff-filter=U)
```

**Stop here.** Do not resolve any conflicting file yourself.
This includes a file where only the release squash commit (`$RELEASE_SHA`) touched it among main-only commits.
A "squash duplicate" appearance does not prove that `dev` already has the content.
apexyard#1348 demonstrates this case, so the skill no longer tries to distinguish safe duplicates from unsafe content.
Treat every conflict the same way.

For each file in `$CONFLICTS`, show the user:

```bash
git diff upstream/dev upstream/main -- "<file>"
git log upstream/dev..upstream/main --oneline -- "<file>"
```

The second command lists every commit on `main` that is not on `dev` and
touched the file, including `$RELEASE_SHA` when applicable. Ask the
user how to resolve the file. Once the user names the resolution, `git add`
the file and continue. Do not pick a side yourself, not even when the list
has only one commit in it.

Once the user resolves every conflicting file, finish the merge:

```bash
git commit --no-edit
```

Wait for the user's answer on every file before running this commit. Do not
commit the merge with a file still unresolved.

### 5b. Carry forward `CHANGELOG.md` from main (apexyard#448)

A user resolving a step 5a conflict usually keeps `dev`'s side.
However, `CHANGELOG.md` differs: every release writes new entries on `main`, and `dev` should retain those entries.
Without this step, release-notes history accumulates only on `main`.
The next `/release` run then prepends a new entry to a stale `dev` CHANGELOG.
The squash-merge silently truncates prior releases on `main`.
See apexyard#446 / #447 for the v2.2.0 symptom.

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
truncate the prior releases, the exact pre-v2.2.0 regression captured in
apexyard#446 and root-caused in apexyard#448.

Refs #448"
  fi
fi
```

**Path-specific by design (v1).** This step targets only `CHANGELOG.md`, the one file the release flow writes on `main`.
Defer support for other "main-leads" files until a second file appears.
That extension would warrant the YAML config option in #448 § "Design Notes".

**Why a separate commit rather than amending the merge.** The carry-forward must remain visible in the audit trail.
A separate commit makes the operation reviewable in the sync PR. Rex can check each of the two commits.
Amending the merge would hide the carry-forward inside the merge commit and obscure the audit trail.

**Idempotent.** On an already-synced repo, `git diff --quiet upstream/main -- CHANGELOG.md` returns 0.
The `if` block skips the update and creates no commit.
Step 2's existing "already in sync" guard still catches the all-empty case.
This guard handles the narrower case where code matches but CHANGELOG drifted during a prior unfixed run.

**What this step does NOT do.**

- Does **not** touch any file other than `CHANGELOG.md`.
- Does **not** modify `main`'s tree. It only updates the sync branch's `CHANGELOG.md` to match.
- Does **not** rewrite history. The carry-forward is a fresh commit on top of the merge commit.
- Does **not** run if `main`'s `CHANGELOG.md` equals dev's post-merge copy. The `if` guard skips the entire block.
- Does **not** preserve in-flight `CHANGELOG.md` edits on `dev`. Under the release-cut model `dev` does NOT add CHANGELOG entries between releases. Only `/release` writes there, so this is the expected steady-state. If an adopter has hand-edited `CHANGELOG.md` on `dev`, the carry-forward overwrites those edits. The right shape for that case is to land the edits via the `/release` skill (or a chore PR) before invoking `/release-sync`.

### 5c. Post-merge check: every main-only commit's content must still be present (apexyard#1394)

After the merge commit exists (steps 5, 5a, and 5b) and before pushing, verify
that the merge preserved every main-only commit's content. For every non-merge commit in
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

`--binary` matters. Without it, `git show` prints a text placeholder for a binary-file change instead of a patch.
`git apply` cannot reverse-apply a placeholder.
Thus, every commit that touched a binary file would falsely fail, regardless of whether its textual content remains.

A commit's patch reverse-applying cleanly means the change it introduced on
`main` is present, unchanged, in the sync branch right now. A name in
`$FAILED_COMMITS` means that commit's content did not check out this way.

**If `FAILED_COMMITS` is non-empty, stop before pushing.** Report each failing
commit's SHA, subject, and touched files (`git show --stat <commit>`) to the
user. Do not push a sync branch that may have lost a main-only commit's
content. This check catches the class of silent loss that `-X ours` caused in apexyard#1348.

This check is best-effort, not a guarantee.
A later main commit can legitimately supersede a commit's content and cause a false failure.
A hunk ending at end-of-file is also sensitive to new content after it in a manually resolved file.
When a commit's changes end the file, place a manual resolution's new lines before the preserved block.
Treat a failure as "investigate", not as an automatic abort.

### 6. Push and open the PR

```bash
git push upstream sync/main-to-dev-after-<version>
gh pr create \
  --repo me2resh/apexyard \
  --base dev \
  --head sync/main-to-dev-after-<version> \
  --title "sync(#403): main→dev after <version> release" \
  --body "<PR body: see template below>"
```

**PR body template:**

```markdown
## Summary

- **Syncs main→dev after the <version> release**: makes the <version> squash commit
  an ancestor of `dev` so the next `dev→main` release PR only sees genuinely-new
  commits instead of fighting the accumulated squash divergence
- **Merge strategy: plain merge, stop and ask on every conflict**: no conflict
  resolves automatically, not even one where the release squash commit is the
  only commit that touched the file. Replaces the blind `-X ours` strategy
  that dropped main-only content with no warning (apexyard#1394).
- **`CHANGELOG.md` is carried forward separately**: the plain merge keeps dev's
  CHANGELOG, so a second commit on top of the merge restores `main`'s
  `CHANGELOG.md` verbatim. Path-specific, audit-trail-visible, idempotent. See apexyard#448.
- **Post-merge check**: every main-only commit's content is verified present
  before push (apexyard#1394); a commit that appears lost stops the sync rather
  than pushing silently.
- **No functional changes**: this is a bookkeeping merge that reconciles SHA
  divergence introduced by the squash-merge release flow; no logic is added or removed

## Background

The apexyard release flow squash-merges dev→main on every release. This creates a
divergence: main has one squash commit (SHA X); dev still has the original un-squashed
commits. A future dev→main release PR then conflicts on all the diffs that X also
touched. v2.0.0 suffered 99 conflicts because of this accumulated gap.

This PR merges main→dev with a plain merge so the squash commit becomes an ancestor
of dev. Future release PRs then only show genuinely-new commits in the diff. The merge
uses a plain strategy, not `-X ours`. `Main` can carry content `dev` never had, and
`-X ours` drops that content silently (apexyard#1348, apexyard#1394).

See [#403](https://github.com/me2resh/apexyard/issues/403) for full root-cause analysis.

## Testing

1. After merging, verify: `git log upstream/dev..upstream/main --oneline` returns empty
2. Verify ancestry, not `main..dev`'s size: `git merge-base --is-ancestor <release-squash-sha> upstream/dev` exits 0.
   (#1002: `git log upstream/main..upstream/dev --oneline` does **not** shrink to "only commits newer than \<version\>".
   Under the release-cut squash model, no individual `dev` commit is reachable from `main`.
   That range accumulates every prior release's un-squashed history, even on a perfectly-synced repo.
   It currently contains ~400 commits. The merge-base check proves that the sync worked.)

3. Verify CHANGELOG is in sync: `diff <(git show upstream/main:CHANGELOG.md) <(git show upstream/dev:CHANGELOG.md)` returns empty (apexyard#448)
4. Verify no main-only commit was lost: the step 5c loop reports an empty `$FAILED_COMMITS` (apexyard#1394)
5. Open a test release PR from dev → main. Confirm only new work appears in the diff and the next `/release` v<next-version> prepends cleanly on top of <version>

Refs #403, #448, #1002, #1394

---

## Glossary

| Term | Definition |
|------|------------|
| Squash divergence | When a release PR is squash-merged to main, the resulting commit has a different SHA than the equivalent dev history, so dev still carries the un-squashed commits as "unsynced" |
| Main-only commit | A commit that exists on `main` and nowhere on `dev`. Examples: a PR merged straight to `main`, a hand-edited file, a hotfix, or a release-branch edit made before the squash. A conflict involving one stops the sync and asks, rather than guessing. |
| `sync/main-to-dev-after-<version>` | Short-lived branch used to carry the merge commit from main into dev; deleted after the PR merges |
| CHANGELOG carry-forward | Path-specific step 5b that restores `main`'s `CHANGELOG.md` on the sync branch after the merge in step 5 would otherwise keep dev's stale copy. Atomic separate commit, idempotent re-run. See apexyard#448. |
| Post-merge content check | Step 5c: for every main-only commit, verify its patch still reverse-applies cleanly against the sync branch, confirming the content survived the merge. See apexyard#1394. |
```

### 7. Stop at PR creation

Do **NOT** merge the sync PR. Rex + CEO approval applies to this PR the same as any other. The skill opens the PR. The operator drives the merge gate.

**CRITICAL: merge strategy for this PR:**

> Merge the sync PR with a **true merge (`--merge`)**. Never use `--squash` or `--rebase`.

The merge commit produced by step 5 above is the artefact that closes ancestry. It carries **two parents**: (1) the dev branch head, and (2) the release squash commit on main. That two-parent relationship is exactly what makes `git merge-base --is-ancestor <release-squash> dev` return true. It makes future release PRs conflict-free.

Squash-merging this sync PR collapses the two-parent merge commit into a single-parent commit. The second parent (pointing at main's release squash) is permanently discarded. Dev gets main's *content* but the release squash is NOT an ancestor of dev. The `git log upstream/dev..upstream/main` divergence check will still show commits after squash. This skill prevents that failure.

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
| Already in sync (`dev..main` is empty) | Exit 0, print `Already in sync — no PR needed.` |
| Tag does not exist yet | Warn `Tag <version> not found on upstream/main — has the release PR merged and been tagged?` then abort |
| Merge produces zero diff (all conflicts resolved to identical content) | Proceed. The merge commit itself is the artefact, even if the tree is identical to dev HEAD |
| Skill invoked on a managed project | Exit 1 with error "release-sync is framework-only" |
| Version not provided | Exit 1 with usage hint |
| Code matches but `CHANGELOG.md` drifted (for example, a prior unfixed `/release-sync` run or manual main edit) | Step 2's `git log dev..main` may be empty yet step 5b's `git diff upstream/main -- CHANGELOG.md` is not. In that case, create the sync branch from `upstream/dev`. Skip step 5's merge because nothing needs merging. Run only step 5b's carry-forward commit. Open the PR with only the CHANGELOG summary in its body. The PR is still useful. It exposes the drift to a reviewer rather than letting the next `/release` silently truncate history. |
| Dev has in-flight edits to `CHANGELOG.md` between releases (unusual) | Carry-forward overwrites them. This is a recognised trade-off. Under the release-cut model `dev` only receives CHANGELOG edits via `/release`. If you need a between-release CHANGELOG edit, merge it via a chore PR before running `/release-sync`. Ensure the file matches on `main` and `dev` when this skill runs. |

## Rules

1. **Framework-only.** Refuse on managed projects.
2. **No auto-merge.** The PR must go through Rex + CEO approval like every other PR.
3. **Branch base is always `upstream/dev`.** Never branch from main for this operation.
4. **Plain merge, stop and ask on every conflict (apexyard#1394).** Never use `-X ours`. Never resolve a conflicting file automatically. This includes files that only the release squash commit touched. Show the user the diff and the touching commits, and wait for their answer.
5. **`--merge` (true merge) on PR merge.** Never `--squash` or `--rebase`. The merge commit IS the ancestry-closure artefact. Destroying it defeats the skill's purpose. `/approve-merge` enforces this automatically on `sync/`-prefixed PRs. A guard in `block-unreviewed-merge.sh` refuses `--squash` on them as a mechanical backstop.
6. **No-op on already-synced repos.** Idempotent: if main has nothing absent from dev, exit 0.
7. **Supply the version argument.** The version labels the sync branch and PR body for auditability.

## Related

- `/release`: the upstream skill that creates the squash divergence. Invoke `/release-sync` as its final step
- `AgDR-0007`: the release-cut branch model this skill stabilises
- `AgDR-0052`: the original design decisions for this skill
- `AgDR-0053`: the decision to use `--merge` (not `--squash`) for sync PRs, and the auto-detect + guard design
- `AgDR-0170`: the decision to replace `-X ours` with a plain merge that stops and asks on every conflict (apexyard#1394)
- `docs/release-process.md`: the prose runbook

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

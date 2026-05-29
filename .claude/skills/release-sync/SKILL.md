---
name: release-sync
description: Sync main back to dev after a squash-merge release — files a PR that makes the release squash commit an ancestor of dev, eliminating future merge conflict accumulation.
argument-hint: "<version, e.g. v2.0.3>"
allowed-tools: Bash, Read, Write
---

# /release-sync — Sync main→dev after a release

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

### 5. Merge main with `-X ours`

```bash
git merge --no-ff -X ours -m "sync: merge main into dev after <version> release

Squash-merge divergence from the <version> release PR creates phantom divergence
between main and dev. This merge makes the <version> squash commit an ancestor
of dev so future dev→main release PRs only see genuinely-new commits.

Strategy: -X ours (dev wins on conflicts) — correct because dev already has the
un-squashed equivalents of everything in the squash commit.

Refs #403" upstream/main
```

**Why `-X ours` and not `-X theirs`?**

We are ON a branch rooted in `dev`. When we run `git merge upstream/main`:

- "ours" = the current branch (dev-based) — this is what we want to win
- "theirs" = the incoming side (main's squash commit)


Dev already has the un-squashed versions of all content in the squash commit. Any conflict means dev's version is the correct authoritative one. `-X ours` preserves dev's content everywhere there's a conflict, which is semantically correct.

**Important:** `-X ours` resolves conflicts automatically. It does NOT mean we wholesale replace main's content. Git will only apply this strategy to the conflict regions, not to content that differs cleanly. The merge will preserve any genuine new content introduced in the release commit that wasn't already in dev.

### 5b. Carry forward `CHANGELOG.md` from main (apexyard#448)

The `-X ours` strategy is correct for *code* — dev already has the un-squashed equivalents and should win on every conflict. But `CHANGELOG.md` is the one file where the opposite is true: every release writes new entries on `main`, and `dev` should track those entries forward. Without this step the release-notes history accumulates only on `main`, and the next `/release` run prepends a new entry on a stale `dev` CHANGELOG and the squash-merge silently truncates the prior releases on `main` (see apexyard#446 / #447 for the symptom this caused for v2.2.0).

After the `-X ours` merge above, **check whether `CHANGELOG.md` on the sync branch differs from `upstream/main`'s copy. If yes, replace it with main's copy and commit it as a separate atomic commit on top of the merge.**

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

The -X ours merge above kept dev's CHANGELOG.md, which lacks the entries
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
- **Merge strategy: `-X ours`** — dev wins on every conflict because dev already
  carries the un-squashed equivalents of all content in the squash commit; the
  strategy is semantically safe and correct in this direction
- **`CHANGELOG.md` is carried forward separately** — `-X ours` would drop the release-notes
  entries written on main, so a second commit on top of the merge restores `main`'s
  `CHANGELOG.md` verbatim. Path-specific, audit-trail-visible, idempotent. See apexyard#448.
- **No functional changes** — this is a bookkeeping merge that reconciles SHA
  divergence introduced by the squash-merge release flow; no logic is added or removed

## Background

The apexyard release flow squash-merges dev→main on every release. This creates a
divergence: main has one squash commit (SHA X); dev still has the original un-squashed
commits. A future dev→main release PR then conflicts on all the diffs that X also
touched. v2.0.0 suffered 99 conflicts because of this accumulated gap.

This PR is the low-ceremony fix: merge main→dev with `-X ours` so the squash commit
becomes an ancestor of dev. Future release PRs then only show genuinely-new commits
in the diff.

See [#403](https://github.com/me2resh/apexyard/issues/403) for full root-cause analysis.

## Testing

1. After merging, verify: `git log upstream/dev..upstream/main --oneline` returns empty
2. Verify: `git log upstream/main..upstream/dev --oneline` shows only commits newer than <version>
3. Verify CHANGELOG is in sync: `diff <(git show upstream/main:CHANGELOG.md) <(git show upstream/dev:CHANGELOG.md)` returns empty (apexyard#448)
4. Open a test release PR from dev → main — confirm only new work appears in the diff and the next `/release` v<next-version> prepends cleanly on top of <version>

Refs #403, #448

---

## Glossary

| Term | Definition |
|------|------------|
| Squash divergence | When a release PR is squash-merged to main, the resulting commit has a different SHA than the equivalent dev history, so dev still carries the un-squashed commits as "unsynced" |
| `-X ours` | Git merge strategy option that resolves conflicts in favour of "our" side — when on a dev-based branch merging main, "ours" = dev, which is correct because dev already has the un-squashed equivalents |
| `sync/main-to-dev-after-<version>` | Short-lived branch used to carry the merge commit from main into dev; deleted after the PR merges |
| CHANGELOG carry-forward | Path-specific step 5b that restores `main`'s `CHANGELOG.md` on the sync branch after the `-X ours` merge would otherwise drop the release-notes entries written on `main`. Atomic separate commit, idempotent re-run. See apexyard#448. |
```

### 7. Stop at PR creation

Do **NOT** merge the sync PR. Rex + CEO approval applies to this PR the same as any other. The skill's job is to open the PR; the operator drives the merge gate.

Print:

```
Sync PR opened: <URL>
Branch: sync/main-to-dev-after-<version> → dev
Commits on main not yet on dev: N
Next step: /code-review, then /approve-merge once Rex approves.
After merge: git log upstream/dev..upstream/main should return empty.
```

## Edge Cases

| Scenario | Behaviour |
|----------|-----------|
| Already in sync (`dev..main` is empty) | Exit 0, print "Already in sync — no PR needed." |
| Tag does not exist yet | Warn "Tag <version> not found on upstream/main — has the release PR merged and been tagged?" then abort |
| Merge produces zero diff (all conflicts resolved to identical content) | Proceed — the merge commit itself is the artefact, even if the tree is identical to dev HEAD |
| Skill invoked on a managed project | Exit 1 with error "release-sync is framework-only" |
| Version not provided | Exit 1 with usage hint |
| Code is synced but `CHANGELOG.md` drifted (prior unfixed `/release-sync` run, manual main edit, etc.) | Step 2's `git log dev..main` may be empty yet step 5b's `git diff upstream/main -- CHANGELOG.md` is not. In that case create the sync branch from `upstream/dev`, skip the `-X ours` merge in step 5 (nothing to merge), run only step 5b's carry-forward commit, and open the PR with the body trimmed to the CHANGELOG-only summary. The PR is still useful — it surfaces the drift to a reviewer rather than letting the next `/release` silently truncate history. |
| Dev has in-flight edits to `CHANGELOG.md` between releases (unusual) | Carry-forward overwrites them. This is a recognised trade-off — under the release-cut model `dev` only receives CHANGELOG edits via `/release`. If you genuinely need a between-release CHANGELOG edit, land it via a chore PR before running `/release-sync` so the file is identical on `main` and `dev` by the time this skill runs. |

## Rules

1. **Framework-only.** Refuse on managed projects.
2. **No auto-merge.** The PR must go through Rex + CEO approval like every other PR.
3. **Branch base is always `upstream/dev`.** Never branch from main for this operation.
4. **Merge strategy is always `-X ours`.** Dev wins on conflicts, always. Do not offer to flip this.
5. **No-op on already-synced repos.** Idempotent: if main has nothing dev doesn't, exit 0.
6. **Version argument is required.** The version labels the sync branch and PR body for auditability.

## Related

- `/release` — the upstream skill that creates the squash divergence; invoke `/release-sync` as its final step
- `AgDR-0007` — the release-cut branch model this skill stabilises
- `AgDR-0052` — the decision record for this skill's design choices
- `docs/release-process.md` — the prose runbook

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

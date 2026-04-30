---
name: update
description: Sync the ApexYard fork (ops repo) with upstream me2resh/apexyard. Fetches upstream, previews pending commits, merges (or rebases) on a sync branch, handles conflicts, and leaves a branch ready to push as a PR. Use when the SessionStart drift banner says the fork is behind, or periodically as fork maintenance.
argument-hint: "[--dry-run] [--rebase]"
allowed-tools: Bash, Read, Write, Edit
---

# /update — Sync ApexYard Fork from Upstream

Single-command replacement for the manual "fetch → branch → merge → push → PR" dance that fork maintainers do to pull upstream apexyard changes into their ops fork.

## Usage

```
/update              # merge-based sync (default, safer)
/update --rebase     # rebase local customisations on top of upstream
/update --dry-run    # preview only, don't touch anything
```

## Output

On success: one sync branch ready to push (e.g. `chore/#N-sync-upstream-apexyard`), with an auto-generated PR body listing the commits pulled in, plus the exact next commands to run.

On conflict: paused at the conflict point with per-file options (keep mine / accept upstream / open editor).

On up-to-date: one line, no state change.

## When NOT to use

- The clone has no `upstream` remote. The skill prints the exact `git remote add upstream …` command and exits.
- The working tree is dirty (uncommitted changes or unstaged files). The skill refuses — stash or commit first.
- The current branch is not the default (`main` / `master`). The skill refuses — `git checkout main` first.
- You want to sync a specific feature branch from upstream. Out of scope — this skill is for default-branch fork sync only.

## Process

### 1. Pre-flight

Run these checks in order. On first failure, stop and explain.

```bash
# 1a. upstream remote exists
git remote | grep -qx upstream || {
  ORIGIN=$(git remote get-url origin)
  echo "No 'upstream' remote configured."
  echo "Add it with:"
  echo "  git remote add upstream https://github.com/me2resh/apexyard.git"
  echo "Then re-run /update."
  exit 1
}

# 1b. working tree is clean
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash first, then re-run /update."
  exit 1
fi

# 1c. on default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's|origin/||')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
  echo "Not on default branch ($DEFAULT_BRANCH). Currently on: $CURRENT_BRANCH"
  echo "Run: git checkout $DEFAULT_BRANCH"
  exit 1
fi
```

### 2. Fetch both remotes

```bash
git fetch upstream --quiet
git fetch origin --quiet
```

Network failure: print a warning and exit. Don't try to "work from cache" — users should know they're seeing stale state.

### 3. Preview

Two signals matter here: a new upstream **tag** (the actionable one, meaning a real release is available), and upstream **main commits** since the fork's last sync (informational — may just be a docs typo).

```bash
AHEAD=$(git rev-list --count upstream/main..main)
BEHIND=$(git rev-list --count main..upstream/main)

# Tag-based signal — same comparison the SessionStart drift banner uses.
UPSTREAM_TAG=$(git tag --list --sort=-v:refname --merged upstream/main | head -n 1)
LOCAL_TAG=$(git tag --list --sort=-v:refname --merged main | head -n 1)
```

Then report. Examples:

**Up-to-date (no tag drift, no commit drift):**

```
Fork is up to date with upstream/main. Nothing to sync.
```

Exit 0.

**No release drift, but main has moved (common, NOT actionable):**

```
Fork is on upstream's latest release (v1.1.0) but upstream/main has 3 unreleased commits.
These are typically docs tweaks, CI fixes, or work-in-progress.

Sync anyway? [y/N]
```

Default answer is "no" — small main commits aren't worth syncing. Surface this without nagging; the user can still choose to pull in bleeding-edge.

**Behind only — new release available (actionable, default):**

```
New release available: v1.1.0 (you are on v1.0.0, 12 commits behind upstream/main).

Upstream commits to pull in:
  c8c93bb fix: merge-gate hooks read PR HEAD via gh pr view (#57)
  1299b59 fix(#47): catch gh api .../merge bypass (#54)
  5f067b5 fix: reject closed issue refs (#53)
  ... (9 more)

Proceed with merge? [Y/n]
```

Default answer is "yes" in this mode — there's a real release the user asked about by running `/update`.

**Ahead and behind (typical fork):**

The prompt's default answer branches on whether a new release is available:

- If `UPSTREAM_TAG` is strictly newer than `LOCAL_TAG` → default `[Y/n]` (there's a real release to pull in).
- If they're equal (no new release, just main drift) → default `[y/N]` (likely noise).

```
Fork has 5 local commits not in upstream, and is 12 commits behind.

Local commits (will be preserved on top of the merge):
  f46d4e7 Merge pull request #2 from …/chore/#40-configure-ops-repo
  840bb2d fix: auto-fix markdown lint in handover assessments
  (… 3 more …)

Upstream commits to pull in:
  c8c93bb fix: merge-gate hooks read PR HEAD via gh pr view (#57)
  (… 11 more …)

New release available: v1.1.0 (you are on v1.0.0).

Proceed with merge? [Y/n]
```

Cap each list at 20 entries with an `(N more)` marker.

If `--dry-run` is set, show the preview and exit without touching anything else.

### 4. Ask merge vs rebase (unless `--rebase` was passed)

If not already specified by flag:

```
Sync strategy:
  (1) merge   — creates a merge commit. Local history is preserved as-is. Safer for shared branches. DEFAULT.
  (2) rebase  — replays local commits on top of upstream. Cleaner linear history but rewrites local SHAs.

Choose [1]:
```

Default is merge. Record the choice.

### 5. Create a sync branch

Rationale for diverging from the `#58` AC wording ("leaves updated local main"): apexyard's own `block-main-push.sh` hook blocks direct pushes to `main` and also blocks commits made while on `main`. A merge with conflicts requires a `git commit` to finalise, which would be blocked. A sync branch sidesteps both issues and is the same shape the project uses for all other changes.

```bash
# Find or create a tracking issue. If a recent "sync" issue is open, reuse its number.
# Otherwise prompt the user to create one (or offer to create it via `gh issue create`).

BRANCH="chore/#${TICKET}-sync-upstream-apexyard"
git checkout -b "$BRANCH"
```

### 6. Do the sync

**Merge path:**

```bash
git merge upstream/main --no-edit
```

**Rebase path:**

```bash
git rebase upstream/main
```

Capture stdout/stderr for the conflict-detection step.

### 7. Handle conflicts (if any)

If merge/rebase reports conflicts, show the user one file at a time:

```
CONFLICT in .claude/rules/pr-workflow.md

Upstream changed:  adds "### Both merge shapes are gated (#47)" section
Local changed:     inserted custom header paragraph at the top

Options:
  (1) Keep mine        — git checkout --ours .claude/rules/pr-workflow.md
  (2) Accept upstream  — git checkout --theirs .claude/rules/pr-workflow.md
  (3) Open in editor   — pause skill, wait for user to resolve, then resume

Choose [3]:
```

For each conflict file, get the user's choice. Default to (3) since auto-resolution on a governance framework is risky.

After each file: `git add <file>` to mark resolved.

When all conflicts are resolved:

```bash
# merge path
git commit --no-edit

# rebase path
git rebase --continue
```

If at any point the user wants to bail:

```bash
git merge --abort    # or: git rebase --abort
git checkout main
git branch -D "$BRANCH"
```

### 8. Final state + next steps

On clean completion, print:

```
Synced to upstream/main @ <SHA> on branch <BRANCH>.

  Commits merged:     <N>
  Files changed:      <F>
  Conflicts resolved: <C>

Next steps (the skill does NOT push — per #58 AC):

  1. Review the merge:
       git log -n 5 --oneline

  2. Push and open the PR:
       git push -u origin <BRANCH>
       gh pr create --title 'chore(#<TICKET>): sync ops fork with upstream apexyard' \\
         --body "$(cat <<'BODY'
## Summary

Sync with upstream me2resh/apexyard — N commits.

## Commits pulled in

<auto-generated list>

## Testing

- Merged cleanly (or: conflicts resolved, listed below)
- Local main untouched until this PR merges to origin

## Glossary

| Term | Definition |
|------|------------|
| ops fork | User's fork of me2resh/apexyard used as Chief-of-Staff ops repo |
| upstream sync | Routine maintenance pull of new framework commits from me2resh/apexyard into the fork |

Closes #<TICKET>
BODY
)"

  3. After the PR merges, fast-forward local main:
       git checkout main && git pull --ff-only

Skill done. No remote state changed.
```

### 9. Edge cases

| Situation | Handling |
|-----------|----------|
| No `upstream` remote | Print `git remote add` command and exit |
| Dirty working tree | Refuse, tell user to stash/commit |
| On non-default branch | Refuse, tell user to checkout main |
| Already up-to-date | One-line report, exit 0 |
| Network failure on fetch | Warn, exit 1 — don't proceed on stale refs |
| User chose rebase but has 50+ local commits | Warn about rewriting many SHAs, re-confirm |
| Merge conflict the user aborts | Restore original branch state, delete sync branch, exit 1 |
| Tracking issue for the sync doesn't exist | Offer to create one via `gh issue create`, get number, continue |

## Design notes

### Why a sync branch instead of merging directly into main

The `#58` AC says "leaves updated local main for the user to push themselves." Two hooks in this repo make literal adherence impossible:

- `block-main-push.sh` blocks `git push <remote> main` (direct push to main is forbidden)
- `block-main-push.sh` also blocks `git commit` while on main — so a merge with conflicts (which requires a commit to finalise) cannot be completed on main

Creating a sync branch is the same shape the project uses for every other change. It also gives the user a concrete thing to `git push -u`, a PR to open, and a merge to review — matching the Rex + CEO approval flow already in place. The trade-off is one extra indirection step vs. matching the rest of the workflow. The latter wins.

### Why merge is the default, not rebase

Forks typically have genuine customisation commits (`onboarding.yaml`, `apexyard.projects.yaml`, `projects/<name>/` additions). Rebasing rewrites those SHAs, which is fine for a solo user but surprising in a team setting. Merge preserves history. Users who prefer a linear log can pass `--rebase`.

### Why the skill does not run Rex or `/approve-merge`

Two reasons:

1. The skill's job ends at "sync branch ready to push." Running Rex would couple two unrelated concerns (upstream sync + code review).
2. Rex + CEO approval is meant to be a discrete, per-PR moment. The skill could call them, but doing so automatically blurs the boundary the approval markers are designed to preserve. User runs Rex + `/approve-merge` themselves on the PR the skill prepared.

### Dry-run semantics

`--dry-run` simulates step 3 (preview) only. It does NOT simulate the merge itself — running `git merge --no-commit --no-ff` as a dry-run leaves the working tree in a staged state that's easy to accidentally commit. If the preview says N commits to pull in, the user should run `/update` for real to see the merge.

## Related

- `docs/multi-project.md` § "Upgrades — pulling from upstream" — the manual flow this skill automates.
- `.claude/rules/pr-workflow.md` — the PR workflow the sync branch will follow.
- `.claude/hooks/block-main-push.sh` — the hook that motivates the sync-branch approach.

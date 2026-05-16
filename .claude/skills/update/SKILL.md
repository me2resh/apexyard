---
name: update
description: Sync the ApexYard fork (ops repo) with upstream me2resh/apexyard. Fetches upstream, previews pending commits, merges (or rebases) on a sync branch, handles conflicts, and leaves a branch ready to push as a PR. Use when the SessionStart drift banner says the fork is behind, or periodically as fork maintenance.
argument-hint: "[--dry-run] [--rebase]"
allowed-tools: Bash, Read, Write, Edit
---

# /update — Sync ApexYard Fork from Upstream

Single-command replacement for the manual "fetch → branch → merge → push → PR" dance that fork maintainers do to pull upstream apexyard changes into their ops fork.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

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

### 0. Mark this session as bootstrap (REQUIRED)

`/update` edits framework-root files (resolving merge conflicts, updating CLAUDE.md imports, etc.) which the `require-active-ticket.sh` PreToolUse hook would otherwise block when the only "ticket" is the upstream-sync work itself. Write a marker so the hook exempts this skill (it's on the default `bootstrap_skills` list in `.claude/project-config.defaults.json`):

```bash
mkdir -p .claude/session && echo "update" > .claude/session/active-bootstrap
```

Clear the marker on completion (last step of this skill). If the skill is interrupted, the SessionStart hook `clear-bootstrap-marker.sh` clears it at the start of the next session. See AgDR-0011 + me2resh/apexyard#150.

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

### 8. Detect deprecated config keys (advisory)

After the merge / rebase has applied (so the new `.claude/project-config.defaults.json` is on disk), scan the adopter's `.claude/project-config.json` for **top-level keys that no longer exist in defaults** — typically a config block removed upstream (e.g. `voice_prompts` removed in me2resh/apexyard#157) that still lingers in the override as dead config.

This is **advisory only**. Custom-extension keys an adopter has added (their own hooks, in-house extensions) are also surfaced — the detector cannot tell them apart from upstream-removed keys, and only the operator can. The y/n/s offer below is the human-in-the-loop step that disambiguates.

#### Detection

Source the helper and read the deprecated key list:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-detect-deprecated-config.sh"
DEPRECATED=$(detect_deprecated_config_keys)
```

Return values:

- Empty → nothing to surface, skip to step 9.
- One or more newline-separated key names → continue.

The helper:

- Reads only **top-level** keys (whole-block removals; sub-key renames are out of scope per the ticket).
- Whitelists metadata keys with a leading underscore (`_comment`, `_schema_version`, `_team_comment`, etc.) — those aren't deprecated config blocks.
- Returns silently with exit 1 if `jq` is missing or defaults file is absent (skill should skip detection in that case, not fail).

#### Offer

If `DEPRECATED` is non-empty, format and print:

```
ApexYard /update detected N config block(s) in .claude/project-config.json
that no longer exist in upstream defaults:

  - voice_prompts
  - abandoned_block

These keys may be:
  (a) dead config from a block the framework removed upstream (e.g.
      voice_prompts after #157), or
  (b) custom extension keys you've added intentionally.

The detector can't tell them apart — choose:

  [y] yes, remove the listed keys from .claude/project-config.json
  [n] no, leave them alone (they're harmless; you can clean up later)
  [s] show me the keys + their current values before deciding
```

Read the operator's reply.

| Reply | Action |
|-------|--------|
| `y` | Run `remove_deprecated_config_keys` (edits `.claude/project-config.json` in place, no commit), then `git add .claude/project-config.json` to stage the change for the operator's review. Print `Removed N keys. Staged for review — diff with: git diff --staged .claude/project-config.json`. |
| `n` | Print `Leaving override untouched. Re-run /update later if you change your mind.` and continue to step 9. |
| `s` | Run `show_deprecated_config_keys` (prints each key + current value), then re-prompt with the same y/n options (no `s` recursion). |

The skill **never auto-removes without explicit `y`**. The skill **never auto-commits** — staging is the contract, the operator owns the commit.

#### Why advisory, not destructive

A custom-extension key indistinguishable from an upstream-removed key is a real possibility (e.g. an adopter who's ahead of defaults with their own block). The cost of incorrectly removing a custom block is much higher than the cost of one extra prompt — the y/n/s pattern matches the rest of `/update`'s "operator owns each material change" stance.

### 8a. Migrate to split-portfolio v2 layout (advisory, default-yes)

Detection. After the merge / rebase has applied the new `_lib-portfolio-paths.sh` + `_lib-ops-root.sh`, source the helper and check for **two** conditions that together identify a pre-v2 split-portfolio adopter:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"

# Already v2 (or single-fork) — no migration needed.
if portfolio_is_v2; then
  V2_NEEDED=0
elif ! jq -e '.portfolio.registry' .claude/project-config.json >/dev/null 2>&1; then
  # No portfolio block at all → single-fork mode → no migration.
  V2_NEEDED=0
else
  # Has a portfolio block (split-portfolio) but no .apexyard-fork marker
  # → pre-v2 split-portfolio adopter. Migration applies.
  V2_NEEDED=1
fi
```

If `V2_NEEDED=0` → skip this step entirely and continue to step 9.

If `V2_NEEDED=1`, present the offer:

```
ApexYard /update detected your fork is in split-portfolio mode (v1 layout):

  - apexyard.projects.yaml     → resolved to a sibling private repo (good)
  - projects/                  → resolved to a sibling private repo (good)
  - onboarding.yaml            → still in this public fork (v1 layout)
  - workspace/                 → still in this public fork (v1 layout)

Split-portfolio v2 (introduced in framework #242) moves onboarding.yaml
AND workspace/ to the private sibling repo too, so the public fork holds
ONLY framework files + your customisations to skills/hooks/rules.

Migrate now? This will:
  - Move onboarding.yaml to the sibling private repo
  - Move workspace/<name>/ contents to the sibling private repo
  - Add gitignore entries for both in the public fork
  - Write a .apexyard-fork marker (the v2 ops-fork anchor)
  - Add portfolio.{onboarding,workspace_dir} keys to .claude/project-config.json

Files MOVED, not copied — destructive. Idempotent — if interrupted, re-run.

[Y / n / dry-run — show commands, don't execute]
```

If `--dry-run` was passed to `/update`, force the dry-run branch automatically (print the commands the migration would run, do not execute, then continue to step 9).

Per-file-class confirmation — ask separately for `onboarding.yaml` and `workspace/`, so the operator can move one and defer the other:

```
Move onboarding.yaml? [Y/n]
Move workspace/? [Y/n]   # surfaces the disk size: du -sh workspace
```

#### Migration steps

For each file class the operator confirmed, run the moves below. Resolve the sibling repo dir from the existing `portfolio.registry` path (the parent dir of the registry file is the sibling repo root):

```bash
SIBLING_ROOT=$(dirname "$(jq -r '.portfolio.registry' .claude/project-config.json)")
# e.g. SIBLING_ROOT=../apexyard-portfolio
```

##### Move onboarding.yaml

```bash
if [ -f onboarding.yaml ] && [ ! -f "$SIBLING_ROOT/onboarding.yaml" ]; then
  mv onboarding.yaml "$SIBLING_ROOT/onboarding.yaml"
  (cd "$SIBLING_ROOT" && git add onboarding.yaml)
elif [ -f "$SIBLING_ROOT/onboarding.yaml" ] && [ -f onboarding.yaml ]; then
  # Both present — surface the conflict and stop. The operator picks.
  # `exit 1` (not `return 1`) — this snippet runs at top-level in the
  # operator's shell when invoked from the skill; `return` would fail
  # outside a function. Wrap the whole step 8a in `( ... )` if you want
  # the exit contained to a subshell.
  printf 'WARNING: onboarding.yaml exists in BOTH the public fork and the sibling repo.\n' >&2
  printf '  Resolve manually before re-running /update.\n' >&2
  exit 1
fi
```

Idempotence: if `onboarding.yaml` is already only in the sibling repo, this block is a no-op.

##### Move workspace/

```bash
if [ -d workspace ] && [ "$(ls -A workspace 2>/dev/null)" ]; then
  mkdir -p "$SIBLING_ROOT/workspace"
  # Move each entry individually so we don't trip on `mv` of a populated dir
  # to an existing dir (some shells refuse).
  for entry in workspace/*; do
    [ -e "$entry" ] || continue
    name=$(basename "$entry")
    # workspace/README.md is a committed framework artefact explaining the
    # workspace/*/ convention — it stays in the public fork (matches the
    # manual recipe in docs/multi-project.md § "What if you want to migrate
    # by hand?"). See AgDR-0021 § G for the rationale.
    if [ "$name" = "README.md" ]; then
      continue
    fi
    if [ -e "$SIBLING_ROOT/workspace/$name" ]; then
      echo "WARNING: workspace/$name exists in BOTH locations — skipped."
      continue
    fi
    mv "$entry" "$SIBLING_ROOT/workspace/$name"
  done
fi
```

Idempotence: empty `workspace/` (no entries to move) is a no-op.

##### Update .gitignore

```bash
NEEDS=()
grep -qxF onboarding.yaml .gitignore 2>/dev/null || NEEDS+=(onboarding.yaml)
grep -qxF workspace .gitignore 2>/dev/null || NEEDS+=(workspace)

if [ "${#NEEDS[@]}" -gt 0 ]; then
  {
    echo ""
    echo "# Split-portfolio v2 (framework ≥ #242): onboarding + workspace live in the private sibling repo."
    for n in "${NEEDS[@]}"; do echo "$n"; done
  } >> .gitignore
  git add .gitignore
fi
```

##### Write the .apexyard-fork marker

The marker is **presence-only**: readers (every ops-root walk) MUST ignore content; only file presence matters. Writers MAY include a single explanatory line so `head .apexyard-fork` is informative — both `echo "# comment" > .apexyard-fork` and `touch .apexyard-fork` are valid. See [AgDR-0021](../../../docs/agdr/AgDR-0021-split-portfolio-v2-path-resolution.md) § B.

```bash
if [ ! -f .apexyard-fork ]; then
  echo "# This file marks the directory as an ApexYard ops fork (split-portfolio v2)." > .apexyard-fork
  git add .apexyard-fork
fi
```

##### Update .claude/project-config.json

Add the two new keys to the `portfolio` block, pointing at the sibling repo. Use `jq` to merge so existing keys are preserved:

```bash
PCONFIG=.claude/project-config.json
if [ -f "$PCONFIG" ]; then
  TMP=$(mktemp)
  jq --arg onb "$SIBLING_ROOT/onboarding.yaml" \
     --arg ws "$SIBLING_ROOT/workspace" \
     '.portfolio.onboarding = (.portfolio.onboarding // $onb)
      | .portfolio.workspace_dir = (.portfolio.workspace_dir // $ws)' \
     "$PCONFIG" > "$TMP" && mv "$TMP" "$PCONFIG"
  git add "$PCONFIG"
fi
```

Idempotence: `// $onb` short-circuits if the operator already added the key by hand.

##### Final verification

```bash
portfolio_clear_cache
if portfolio_validate >/dev/null 2>&1; then
  echo "✓ Migration to split-portfolio v2 layout complete."
  echo "  Files moved to: $SIBLING_ROOT"
  echo "  Public-fork changes staged for review (git diff --cached)."
  echo "  Don't forget to commit + push the sibling repo as well:"
  echo "    cd $SIBLING_ROOT && git status"
else
  echo "✗ Migration left portfolio_validate broken — fix manually:"
  portfolio_validate
fi
```

The skill **does not commit** — staging is the contract; the operator owns both the public-fork commit AND the sibling-repo commit.

#### Why advisory, not silent

The migration moves real files between repos. If the operator has a custom workflow built on top of the in-fork `workspace/` location, an automatic move would silently break it. The y/n/dry-run pattern matches the deprecated-config-key offer in step 8 — operator owns each material change.

### 9. Final state + next steps

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

### 10. Edge cases

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
| `jq` not installed (deprecated-config detection) | Skip step 8 silently; print one-line warning. The sync itself still completes. |
| `.claude/project-config.json` missing (no override) | Skip step 8 silently — by definition no deprecated keys to surface. |
| Operator answered `s` (show) | Print key + value, then re-prompt y/n (no `s` recursion). |

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

## Cleanup (REQUIRED before exit)

```bash
rm -f .claude/session/active-bootstrap
```

Always remove the bootstrap marker on a clean exit (after the sync branch is ready to push, or on a confirmed-abort during conflict resolution). If the skill is interrupted, `clear-bootstrap-marker.sh` clears the stale marker on the next session.

## Related

- `docs/multi-project.md` § "Upgrades — pulling from upstream" — the manual flow this skill automates.
- `.claude/rules/pr-workflow.md` — the PR workflow the sync branch will follow.
- `.claude/hooks/block-main-push.sh` — the hook that motivates the sync-branch approach.

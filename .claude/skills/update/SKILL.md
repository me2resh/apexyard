---
name: update
description: Sync the ApexYard fork with upstream — preview, merge-or-rebase on a sync branch, walk per-version migrations.
argument-hint: "[--dry-run] [--rebase] [--from-version vN.N.N] [--skip-migrations]"
allowed-tools: Bash, Read, Write, Edit
---

<!--
  Hidden flag: --from-dev (NOT in description above, on purpose — see #250).
  Pulls from upstream/dev instead of the latest tagged release. Adopter
  contract is tagged releases; --from-dev is an opt-in for framework
  maintainers and adopters who explicitly want to test pre-release work.
  Documented in `## Usage` and `## Options` below for operators who read
  the spec; deliberately omitted from `description` so /help does not
  surface it.
-->


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
/update                              # merge-based sync (default, safer)
/update --rebase                     # rebase local customisations on top of upstream
/update --dry-run                    # preview only, don't touch anything
/update --from-version v1.2.0        # override the version anchor (use when fork anchor is missing/wrong)
/update --skip-migrations            # files-only sync; do NOT run the per-version migration chain
/update --from-dev                   # (hidden) pull from upstream/dev — pre-release; expect breakage
```

## Options

| Flag | Effect |
|------|--------|
| `--rebase` | Rebase local commits onto upstream instead of merging. Cleaner linear history; rewrites local SHAs. |
| `--dry-run` | Run the preview step only. Print the commit delta and exit; no fetch-after-preview, no branch creation, no merge. **Does NOT execute migrations** — only previews the planned chain. |
| `--from-version vN.N.N` | Explicit version-anchor override. Use when `.claude/framework-version` is missing (legacy fork pre-v1.4.0) OR you've manually rolled back and the anchor is stale. The chain is built against this value instead of the file. Refuses if the value doesn't match `vMAJOR.MINOR.PATCH`. |
| `--skip-migrations` | Sync the framework files but DO NOT run the per-version migration chain. Prints an advisory warning naming each skipped pair and reminding the operator that the migrations can be replayed later with `bash .claude/migrations/<pair>.sh`. The anchor file IS still advanced to the new release tag, so subsequent runs won't re-offer the same migrations. Use sparingly — the chain is the point. |
| `--from-dev` | **Hidden / opt-in.** Sync from `upstream/dev` (pre-release work) instead of the latest `upstream/main` tag. Prints a `⚠ PRE-RELEASE SYNC` banner BEFORE any fetch/state-mutation. Same sync-branch + conflict-resolution flow; branch is named `chore/sync-upstream-dev` (or `chore/#<TICKET>-sync-upstream-dev` if a tracking issue is supplied). Intended for the framework maintainer (testing pre-release work on another machine) and for adopters who explicitly want to validate an upcoming framework change. **Not** in the skill's `description` frontmatter on purpose — `/help` should not surface it, since the adopter contract is tagged releases (see AgDR-0007 release-cut model). Combinable with `--rebase` and `--dry-run`. **When `--from-dev` is set, the migration chain is automatically skipped** — pre-release work doesn't have a release tag to anchor against. |

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

### Pre-step: Parse flags + print pre-release banner (when --from-dev)

Parse the invocation arguments first, BEFORE any fetch / branch / merge work:

```bash
FROM_DEV=0
DRY_RUN=0
REBASE=0
SKIP_MIGRATIONS=0
FROM_VERSION_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from-dev)         FROM_DEV=1 ;;
    --dry-run)          DRY_RUN=1 ;;
    --rebase)           REBASE=1 ;;
    --skip-migrations)  SKIP_MIGRATIONS=1 ;;
    --from-version)     shift; FROM_VERSION_OVERRIDE="$1" ;;
    --from-version=*)   FROM_VERSION_OVERRIDE="${1#--from-version=}" ;;
  esac
  shift
done

# Resolve the upstream ref + sync-branch suffix once, at the top, so every
# downstream step references the same target.
if [ "$FROM_DEV" = "1" ]; then
  UPSTREAM_REF=upstream/dev
  BRANCH_SUFFIX=sync-upstream-dev
  # Pre-release work has no release tag — chain walking is meaningless.
  SKIP_MIGRATIONS=1
else
  UPSTREAM_REF=upstream/main
  BRANCH_SUFFIX=sync-upstream-apexyard
fi

# Validate --from-version shape early (semver-core only; pre-release suffix
# is not supported, in line with the chain helper's contract).
if [ -n "$FROM_VERSION_OVERRIDE" ]; then
  if ! echo "$FROM_VERSION_OVERRIDE" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "--from-version: expected vMAJOR.MINOR.PATCH (got '$FROM_VERSION_OVERRIDE')." >&2
    exit 1
  fi
fi
```

If `FROM_DEV=1`, print this banner BEFORE doing anything else (in particular, before any `git fetch`, branch-create, or merge — operator must see the warning before any state mutation):

```
⚠ PRE-RELEASE SYNC — pulling from upstream/dev
   This is unreleased work; expect breakage.
   Revert with: git reset --hard origin/main
   For supported updates, use /update (no flag) to pull tagged releases.
```

The banner restates the deal every invocation — an operator who used `--from-dev` once should not be surprised the next time they run plain `/update` and find themselves on a different code path. The banner is load-bearing on purpose: dropping it would let pre-release breakage land silently.

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

`git fetch upstream --quiet` brings down all upstream branches by default (including `upstream/dev`), so a single fetch covers both the default and the `--from-dev` target. No conditional fetch needed.

```bash
git fetch upstream --quiet
git fetch origin --quiet
```

Network failure: print a warning and exit. Don't try to "work from cache" — users should know they're seeing stale state.

### 3. Preview

Two signals matter here: a new upstream **tag** (the actionable one, meaning a real release is available), and upstream **main commits** since the fork's last sync (informational — may just be a docs typo).

When `--from-dev` is set, the comparison target is `upstream/dev` instead of `upstream/main`, and tag-based signals are skipped (dev is by definition pre-release; there is no tag to compare against). The preview reports the commit delta against `upstream/dev` and the operator decides whether to proceed.

```bash
AHEAD=$(git rev-list --count "$UPSTREAM_REF"..main)
BEHIND=$(git rev-list --count main.."$UPSTREAM_REF")

# Tag-based signal applies only to the tagged-release path.
if [ "$FROM_DEV" = "0" ]; then
  UPSTREAM_TAG=$(git tag --list --sort=-v:refname --merged upstream/main | head -n 1)
  LOCAL_TAG=$(git tag --list --sort=-v:refname --merged main | head -n 1)
fi
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

**`--from-dev` (pre-release):**

```
Pre-release sync: 7 unreleased commits on upstream/dev since fork's HEAD.

Upstream/dev commits to pull in:
  ab12cde feat(#250): /update --from-dev hidden flag
  cd34efg fix(#248): tighten validation
  ... (5 more)

Proceed with merge from upstream/dev? [Y/n]
```

Default answer is "yes" — the operator opted into pre-release explicitly with the flag, the banner already warned them about breakage, and asking again would be nagging. Skip the tag-based prompts entirely; dev has no tags to compare.

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

# $BRANCH_SUFFIX was set in the pre-step:
#   sync-upstream-apexyard  for upstream/main (default)
#   sync-upstream-dev       for upstream/dev (--from-dev)
if [ -n "$TICKET" ]; then
  BRANCH="chore/#${TICKET}-${BRANCH_SUFFIX}"
else
  BRANCH="chore/${BRANCH_SUFFIX}"
fi
git checkout -b "$BRANCH"
```

### 6. Do the sync

`$UPSTREAM_REF` was set in the pre-step (`upstream/main` by default, `upstream/dev` under `--from-dev`).

**Merge path:**

```bash
git merge "$UPSTREAM_REF" --no-edit
```

**Rebase path:**

```bash
git rebase "$UPSTREAM_REF"
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

### 8b. Walk the intermediate-release migration chain

When an adopter jumps multiple releases at once (e.g. v1.0.0 → v1.4.0) the framework needs to run **every** per-version migration in order, not just the latest. The chain walker reads `.claude/framework-version` (the version anchor), compares against the latest upstream tag, builds the ordered list of pairs, and offers each migration with a `[Y / n / show-diff / skip-all]` prompt.

See [`AgDR-0032`](../../../docs/agdr/AgDR-0032-update-chain-migrations.md) for the design rationale (why a file anchor over derived signals, why per-pair scripts, why per-step confirmation).

This step **always** runs after step 8a (which handles the legacy single-shot split-portfolio v1→v2 detection — that migration is now also encoded as the `v1.2.0-to-v1.3.0.sh` chain script for adopters whose anchor file says they're still on v1.2.0). Step 8a remains as a fallback for adopters who lack the version anchor entirely and would otherwise miss the split-portfolio migration.

#### Detection

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-migration-chain.sh"

# Where are we now? Falls back to "unknown" if the anchor is absent.
CURRENT_VERSION=$(migration_current_version)

# Operator override always wins (covers the "anchor lost" case).
if [ -n "$FROM_VERSION_OVERRIDE" ]; then
  CURRENT_VERSION="$FROM_VERSION_OVERRIDE"
fi

# Target is the latest tag we just pulled in.
TARGET_VERSION=$(git tag --list --sort=-v:refname --merged upstream/main | head -n 1)
```

If `TARGET_VERSION` is empty (no tags reachable — rare but possible on a fresh fork), skip the chain entirely and print one warning line.

#### "Unknown" anchor branch — interactive

If `CURRENT_VERSION="unknown"` AND `--from-version` was NOT passed:

```
ApexYard /update: no .claude/framework-version anchor in this fork.
This is normal on a fork created before framework v1.4.0.

To run the per-version migration chain to <TARGET_VERSION>, I need to
know which release this fork was last aligned with. Options:

  [a] v1.0.0  — earliest tagged release
  [b] v1.1.0
  [c] v1.2.0
  [d] v1.3.0  — most recent before <TARGET_VERSION>
  [e] skip migrations (files-only — advance anchor to <TARGET_VERSION> with no migrations)
  [f] abort sync

Choose [d]:
```

Default is the second-newest tag (most likely the case for adopters who synced recently but predate the anchor file). The list is built dynamically from `migration_known_versions` so future releases auto-extend the menu.

`[e]` is the same code path as `--skip-migrations` but reached through the interactive flow.

`[f]` aborts the sync, restores the original branch state, and exits 1 — the operator can rerun `/update --from-version vN.N.N` once they've confirmed which version their fork is on.

#### Build the chain

```bash
CHAIN=$(migration_chain "$CURRENT_VERSION" "$TARGET_VERSION")
```

| Result | Meaning |
|--------|---------|
| Non-empty newline-separated list | The chain we'll walk |
| Empty AND `CURRENT_VERSION = TARGET_VERSION` | Already up to date, skip cleanly |
| Empty AND `CURRENT_VERSION > TARGET_VERSION` | Going backwards — refuse; print warning; skip the chain |
| Empty AND a known link is missing | Refuse (a release without a migration script is a framework bug — log and bail) |

When the chain is non-empty, print the planned walk before running anything:

```
Per-version migration chain (3 steps):
  1. v1.0.0 → v1.1.0   (.claude/migrations/v1.0.0-to-v1.1.0.sh)
  2. v1.1.0 → v1.2.0   (.claude/migrations/v1.1.0-to-v1.2.0.sh)
  3. v1.2.0 → v1.3.0   (.claude/migrations/v1.2.0-to-v1.3.0.sh)

Each step is operator-confirmable. You can skip any individual step,
skip the rest with `skip-all`, or see the script with `show-diff`.
```

If `--dry-run` is set, print the chain and exit before any `migration_run` invocation.

#### Per-step prompt

For each pair in the chain, prompt:

```
Step N/M — <PAIR>
  Script: .claude/migrations/<PAIR>.sh
  Lines:  <wc -l output>

[Y] apply (run the script)
[n] skip this step (advance anchor anyway)
[d] show-diff (print the script body, then re-prompt y/n)
[a] skip-all remaining steps
```

Default `[Y]`. On `d`, print the script and re-prompt (no `d` recursion). On `a`, set a one-shot flag and skip all remaining steps (anchor still advances).

#### Run the migration

```bash
# Exit code contract:
#   0 — applied (or no-op success branch)
#   1 — conflict needs operator
#   2 — hard error

migration_run "$PAIR"
case "$?" in
  0)
    echo "  ✓ $PAIR applied"
    ;;
  1)
    echo "  ⚠ $PAIR reported a conflict — pausing the chain."
    echo "  Resolve manually, then resume with:"
    echo "    APEXYARD_RESUME_FROM=$PAIR /update"
    exit 1
    ;;
  2)
    echo "  ✗ $PAIR exited with a hard error — aborting chain."
    exit 2
    ;;
esac
```

#### After the chain (always)

Whether the operator applied all, skipped some, or used `--skip-migrations`, write the anchor:

```bash
migration_write_anchor "$TARGET_VERSION"
git add .claude/framework-version 2>/dev/null || true
```

Surfaces in the final-state report (step 9) as one line:

```
Framework version anchor advanced: <CURRENT> → <TARGET_VERSION>
```

If migrations were skipped, list them with the replay hint:

```
Skipped migrations (replay later with bash .claude/migrations/<pair>.sh):
  - v1.1.0-to-v1.2.0
  - v1.2.0-to-v1.3.0
```

### 9. Final state + next steps

On clean completion, print (substituting `$UPSTREAM_REF` for the literal `upstream/main` so the operator sees the actual ref synced under `--from-dev`):

```
Synced to <UPSTREAM_REF> @ <SHA> on branch <BRANCH>.

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
| `--from-dev` passed but `upstream/dev` doesn't exist on the configured remote | Print: `upstream/dev not found — the configured upstream may not have a dev branch. Verify with: git ls-remote upstream dev`. Exit 1; no banner-suppression, no fallback to main. |
| `--from-dev` combined with `--dry-run` | Banner prints first, then preview against `upstream/dev`, then exit 0. Same no-state-change semantics as plain `--dry-run`. |
| `--from-dev` combined with `--rebase` | Allowed. Pre-release commits are rebased on top instead of merged; banner + branch convention unchanged. |
| Anchor file missing AND `--from-version` not passed | Step 8b prompts interactively for the from-version (list built from `migration_known_versions`). Operator picks one or chooses skip / abort. |
| Anchor file says `unknown` (malformed content) | Treated identically to missing — interactive prompt in step 8b. |
| Chain has a missing link (release shipped without a migration script) | Refuse with a clear message naming the gap; advance the anchor anyway so subsequent runs don't loop on the same gap. This is a framework bug — file an issue. |
| `--skip-migrations` passed | Chain detection runs (printed for visibility) but no `migration_run` invocations. Anchor still advances. |
| Individual migration exits 1 (conflict) | Chain pauses. Anchor NOT advanced. Operator resolves, then re-runs `/update`. |
| Individual migration exits 2 (hard error) | Chain aborts. Anchor NOT advanced. Print the script's stderr and exit 2. |
| `--from-version` argument fails the semver regex | Refuse with `--from-version: expected vMAJOR.MINOR.PATCH (got 'X')`. Exit 1 before any fetch. |
| `--from-dev` set | Migration chain auto-skipped (pre-release has no tag to anchor against). Anchor file not advanced — `--from-dev` is the only path that leaves the anchor untouched. |

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

### Why `--from-dev` is hidden (#250)

The framework's adopter contract is "tagged releases from `upstream/main`" (release-cut model — see [AgDR-0007](../../../docs/agdr/AgDR-0007-release-cut-branch-model.md)). Adopters who pull from `dev` are signing up for breakage between releases — that's an opt-in behaviour, not a default. Three design choices flow from this:

1. **Not in `description` frontmatter.** `/help` enumerates skill descriptions; surfacing `--from-dev` there would invite casual use and defeat the release-cut model's stability promise. The flag IS in `## Usage` and `## Options` so an operator who reads the spec finds it.
2. **Banner before any state mutation.** An operator who used `--from-dev` once may not remember the deal next time. The banner prints BEFORE the first `git fetch`, restating the deal every invocation. Dropping it would let pre-release breakage land silently.
3. **Same sync-branch + conflict-resolution flow as the default path.** A separate `/update-dev` skill would duplicate ~95% of the logic for a one-line flag-check difference; the flag-on-existing-skill shape is cheaper to maintain and means every safety check (sync branch, conflict resolution, no auto-merge) applies identically.

Use cases that motivated the flag: the framework maintainer testing pre-release work on a separate machine before cutting a release tag; adopters validating an upcoming framework change before the wider rollout; CI workflows pinning to dev for integration testing (rare but legitimate).

### Why a file-based version anchor (`.claude/framework-version`)

The chain walker needs to know *which release this fork was last aligned with*. Three options were on the table — see [`AgDR-0032`](../../../docs/agdr/AgDR-0032-update-chain-migrations.md) for the full comparison:

| Option | Why we didn't pick it |
|--------|----------------------|
| Derive from the most recent merge-from-upstream commit's tag | Fragile under squash-merge, rebase, and `/update --rebase`. Adopters routinely rewrite history; a derived signal would silently drift. |
| `framework_version` key in `.claude/project-config.json` | Mixes a *measured* fact (which release am I on?) with *configured* facts (custom paths, feature toggles). Adopters edit project-config by hand; the anchor would drift on copy/paste. |
| **Standalone file `.claude/framework-version` (CHOSEN)** | One line, one job: the version of the framework this fork last synced against. Easy to read, easy to write, robust to history rewrites. /update owns it. |

### Why per-pair scripts, not one monolithic migration

Each script is **bounded to one release transition**, which means:

1. **Bisection works** — if the v1.3.0 step fails, the operator knows which fix to write without untangling four releases of changes.
2. **Replay is meaningful** — `bash .claude/migrations/v1.2.0-to-v1.3.0.sh` is a complete, idempotent operation. Replaying a chain step from a monolithic script is much harder.
3. **The chain shape stays in source-control history** — every release that ships either adds a real migration OR a no-op placeholder. A v1.5.0 adopter looking at `.claude/migrations/` sees an exhaustive list of "what changed for adopters at each release".

The cost is **discipline at release-cut time**: skipping a release in the chain (forgetting to file the no-op placeholder) makes the chain refuse to walk past it. The `/release` skill's PR template includes a "did we add a migration script for this release?" checkbox to catch the omission.

## Cleanup (REQUIRED before exit)

```bash
rm -f .claude/session/active-bootstrap
```

Always remove the bootstrap marker on a clean exit (after the sync branch is ready to push, or on a confirmed-abort during conflict resolution). If the skill is interrupted, `clear-bootstrap-marker.sh` clears the stale marker on the next session.

## Related

- `docs/multi-project.md` § "Upgrades — pulling from upstream" — the manual flow this skill automates.
- `docs/upgrading.md` — adopter-facing reference for the multi-hop migration chain.
- `docs/agdr/AgDR-0032-update-chain-migrations.md` — design rationale for the version anchor + per-pair migrations.
- `.claude/hooks/_lib-migration-chain.sh` — the chain detection + run library.
- `.claude/migrations/README.md` — convention for authoring a new per-version migration script.
- `.claude/rules/pr-workflow.md` — the PR workflow the sync branch will follow.
- `.claude/hooks/block-main-push.sh` — the hook that motivates the sync-branch approach.

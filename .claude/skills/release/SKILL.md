---
name: release
description: Cut an apexyard release — diff dev↔main, pick semver bump, generate CHANGELOG, open release PR, auto-tag on merge.
argument-hint: "[--dry-run] [<version, e.g. v1.2.0>]"
allowed-tools: Bash, Read, Write
---

# /release — Cut an apexyard release

Standardises the `dev` → `main` release flow introduced by AgDR-0007. Reads the conventional-commit log between `main` and `dev`, proposes a semver bump, **generates and writes the CHANGELOG entry**, **opens the release PR** (dev→main), and triggers the `auto-tag-on-release-pr-merge` GitHub Actions workflow that tags the squash commit and creates a GitHub Release after merge. One command drives the operator from "nothing" to "PR open, ready for Rex + CEO". The tag and GitHub Release entry are created automatically by CI when the PR merges. The release PR also records a `Released-From` trailer with the exact `dev` cut-point SHA, and the changelog step warns loudly on a large main↔dev commit-count mismatch — both close the #872 changelog-truncation gap. Design rationale: AgDR-0076, AgDR-0094.

This skill is **framework-only** — it's for cutting apexyard releases, not for releasing managed projects under governance. Managed projects stay trunk-based and don't have a release-cut flow.

## Usage

```
/release             # auto-detect bump from conventional commits
/release v1.2.0      # explicit version, skip auto-detect
/release --dry-run   # preview changelog + PR body without writing any files
/release --dry-run v1.2.0
```

## Process

### 1. Pre-flight

Verify:

- Current repo IS the apexyard framework (origin or upstream is `me2resh/apexyard`). Refuse otherwise — this skill is framework-only.
- Working tree is clean. Refuse if uncommitted changes.
- `dev` branch exists (`git rev-parse --verify upstream/dev`). Refuse if absent — adopt the dev/main model first.
- `dev` is ahead of `main` by ≥ 1 commit. Refuse if equal — nothing to release.

### 2. Pick a version

If `<version>` arg was passed, use it (must match `v\d+\.\d+\.\d+`).

Otherwise auto-detect from the conventional-commit types in `git log upstream/main..upstream/dev`:

| Found | Bump |
|-------|------|
| Any commit subject starts with `feat!:` / `feat(...)!:` / `<type>!:` (breaking marker) | **MAJOR** |
| Any `feat:` / `feat(...):` (and no breaking) | **MINOR** |
| Only `fix:` / `chore:` / `docs:` / `refactor:` / `test:` / `style:` / `perf:` / `build:` / `ci:` (and no `feat:` or breaking) | **PATCH** |

Read the current latest tag:

```bash
PREV_TAG=$(git describe --tags --abbrev=0 upstream/main 2>/dev/null \
           || gh api repos/me2resh/apexyard/releases/latest --jq '.tag_name' 2>/dev/null \
           || echo "NONE")
```

Bump accordingly. Show the user:

```
Current latest tag: vX.Y.Z
Proposed next:      vA.B.C  (MINOR — N feat commits, M fix commits)
Override? [Enter to accept, or type a version like v1.3.0]
```

### 3. Generate the CHANGELOG draft

Call the helper script `bin/release-changelog.sh`, which encapsulates the `git log` + conventional-commit grouping + PR-number extraction logic and is independently tested. Capture its output — the count-mismatch guard below needs it:

```bash
CHANGELOG_DRAFT=$(PREV_TAG="vX.Y.Z" \
  HEAD_REF="upstream/dev" \
  VERSION="vA.B.C" \
  DATE="$(date +%F)" \
  bash bin/release-changelog.sh)
echo "$CHANGELOG_DRAFT"
```

The helper emits markdown to stdout in the format:

```markdown
## [vA.B.C] — YYYY-MM-DD

Minor release — N features, M fixes.

### Added (feat)
- (#NN) <subject> — <short-sha>
...

### Fixed (fix)
- (#NN) <subject> — <short-sha>

### Changed (refactor / chore / docs)
- (#NN) <subject> — <short-sha>

### Breaking
- <only if breaking-marker commits exist>

### Closes
- Closes #N, #M, ...
```

#### Count-mismatch guard (AgDR-0094, option D)

Immediately after generating the draft, sanity-check its entry count against the raw commit count between `main` and `dev`. This is the cheap, always-on backstop behind the `Released-From` trailer (step 4) — it's what caught the v5.0.0 under-count by hand, and it stays even after the trailer exists as defence in depth against a mangled trailer or a trailer-less pre-AgDR-0094 tag:

```bash
RAW_COUNT=$(git rev-list --count upstream/main..upstream/dev)
# Count changelog entry bullets (every "- " line except the trailing "Closes" summary).
ENTRY_COUNT=$(printf '%s\n' "$CHANGELOG_DRAFT" | grep -cE '^- ' || true)
[ -n "$ENTRY_COUNT" ] || ENTRY_COUNT=0
GAP=$(( RAW_COUNT - ENTRY_COUNT ))
# Tolerance: release/sync/"Merge branch" marker commits are excluded from the
# changelog BY DESIGN (bin/release-changelog.sh's classify step) — a handful
# of those is normal, not a bug. A gap much larger than that is the #872
# signature (a silently truncated range).
TOLERANCE=5
if [ "$GAP" -gt "$TOLERANCE" ]; then
  echo "⚠️  WARNING: main..dev has $RAW_COUNT commits but the changelog lists only $ENTRY_COUNT entries (gap: $GAP, tolerance: $TOLERANCE)."
  echo "    This is the #872 signature — a truncated changelog range. Verify PREV_TAG/HEAD_REF and the generated LOG_RANGE before proceeding."
fi
```

**Show the draft** (and the warning, if any) and let the user edit interactively before proceeding. On `--dry-run`, print the draft and stop here with:

```
Dry run — no changes made. Remove --dry-run to execute.
```

### 4. Prepare and push the release branch

Skip all of steps 4–5 on `--dry-run`.

```bash
# Check out the release branch from dev
git fetch upstream

# AgDR-0094: record the exact cut point NOW, while it's still knowable. This is
# the sha bin/release-changelog.sh will read back out of the NEXT release's
# PREV_TAG trailer — capture it here, not after checkout (the ref is what
# matters, not the local branch's HEAD, but capturing immediately after fetch
# keeps this unambiguous).
DEV_SHA=$(git rev-parse upstream/dev)

git checkout -b "release/vA.B.C" upstream/dev

# Write the CHANGELOG entry at the top of CHANGELOG.md
# (prepend the draft from step 3 above the previous top entry)

git add CHANGELOG.md
git commit -m "chore: release vA.B.C

- Prepend CHANGELOG section for vA.B.C

Refs #<release-ticket>"

# Push to upstream (not origin — release PRs target me2resh/apexyard)
git push upstream "release/vA.B.C"
```

### 5. Open the release PR

```bash
gh pr create \
  --repo me2resh/apexyard \
  --base main \
  --head "release/vA.B.C" \
  --title "release(#<release-ticket>): vA.B.C" \
  --body-file /tmp/release-pr-body.md
```

**PR body template** (write to `/tmp/release-pr-body.md` before the `gh pr create` call). Interpolate `$DEV_SHA` (captured above) into the final line — it MUST be the very last line of the file, with nothing after it, so it lands as the final paragraph of the squash commit message and `git interpret-trailers` parses it (AgDR-0094):

```markdown
<!-- multi-close: approved -->

## Summary

- **Releases vA.B.C** — see CHANGELOG section below for the full list of changes included in this release
- **CHANGELOG.md updated** — new section prepended at the top with grouped feat/fix/chore entries and PR refs
- **Auto-tag on merge** — `.github/workflows/auto-tag-on-release-pr-merge.yml` will tag the squash commit on main and create a GitHub Release entry automatically when this PR merges (AgDR-0076)
- **Release provenance recorded** — a `Released-From` trailer captures the exact `dev` SHA this release was cut from, so the next release's changelog range is deterministic instead of inferred (AgDR-0094, #872)

## CHANGELOG

<paste the draft from step 3>

## Testing

1. After merge, confirm CI creates tag `vA.B.C` on `main` (check the `auto-tag-on-release-pr-merge` workflow run)
2. Verify `git describe --tags --abbrev=0 upstream/main` returns `vA.B.C`
3. Run `/release-sync vA.B.C` to sync main→dev and prevent squash divergence
4. Verify the squash commit's message carries the trailer: `git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly)' vA.B.C`

Refs #<release-ticket>

---

## Glossary

| Term | Definition |
|------|------------|
| Squash merge | GitHub merges all commits on the PR branch into a single commit on main; the branch HEAD is discarded and the resulting main tip has a new SHA |
| Auto-tag | The `auto-tag-on-release-pr-merge.yml` workflow fires on `pull_request` → `closed` + `merged` for `release/v*` branches, tags `github.sha` (the squash commit), and creates a GitHub Release |
| Ancestry guard | `git merge-base --is-ancestor <sha> main` — fails if the tag would not be reachable from main, preventing a mis-placed tag like v2.3.0 |
| `/release-sync` | The mandatory follow-up skill that merges main→dev after a squash-merge release, preventing SHA divergence accumulation |
| `Released-From` trailer | A git trailer (`Key: value` in the commit message's final paragraph) recording the exact `dev` SHA this release was cut from — `bin/release-changelog.sh` reads it back for the next release's changelog range (AgDR-0094) |

Released-From: $DEV_SHA
```

**Why the trailer sits after the Glossary, as its own final paragraph:** `git interpret-trailers` (and the `%(trailers:...)` pretty-format used by `bin/release-changelog.sh`) only recognises a trailer block when it is the LAST paragraph of the message — a blank line before it, nothing but `Key: value` lines after it. Putting `Released-From:` anywhere earlier (e.g. inside the Summary or Testing sections) would make it invisible to the reader on the next release cut. Do not add anything below the trailer line.

**PR title format** (`release` is whitelisted in `pr.title_type_whitelist` since #168):

```
release(#<release-ticket>): vA.B.C
```

### 6. Wait for review + merge (operator step)

The release PR runs through the normal flow:

- Code Reviewer (Rex) on the PR via `/code-review`
- CEO `/approve-merge`
- Merge gate green
- Squash-merge to `main`

`/release` does **not** auto-merge. The CEO retains the discrete moment. The tag and GitHub Release are created automatically by the `auto-tag-on-release-pr-merge.yml` CI workflow **after** the merge.

### 7. Tag + GitHub Release (automated via CI)

When the release PR is squash-merged to `main`, the `.github/workflows/auto-tag-on-release-pr-merge.yml` workflow fires automatically:

1. Extracts the version from the branch name (`release/vA.B.C` → `vA.B.C`).
2. Uses `github.sha` (the squash commit SHA — already the correct commit on `main`).
3. Runs the ancestry guard: `git merge-base --is-ancestor <sha> main`.
4. Creates an annotated tag and pushes it with `git push origin --tags`.
5. Creates a GitHub Release entry from the CHANGELOG section in the PR body (in the same job — a tag pushed via GITHUB_TOKEN does not trigger a secondary release workflow).

**No manual tagging required** after merge. The workflow handles it.

#### Manual fallback (if CI workflow fails)

If the auto-tag workflow fails for any reason, follow the manual steps:

```bash
# 1. Fetch so upstream/main points at the squash commit.
git fetch upstream

# 2. Tag the tip of upstream/main (the squash commit, NOT the branch HEAD).
git tag vA.B.C upstream/main

# 3. Ancestry guard before pushing.
if ! git merge-base --is-ancestor vA.B.C upstream/main; then
  echo "ERROR: tag is mis-placed — delete and re-tag." >&2
  exit 1
fi

# 4. Push the tag (use --tags, not the bare tag name, to avoid the
#    branch-name validator hook misfiring on tag-push commands).
git push upstream --tags
```

#### Post-tag release checklist

Verify all three assertions hold (CI workflow also checks these):

- [ ] `git merge-base --is-ancestor vA.B.C upstream/main` exits 0
- [ ] `git describe --tags --abbrev=0 upstream/main` returns `vA.B.C`
- [ ] GitHub Release entry exists at `https://github.com/me2resh/apexyard/releases/tag/vA.B.C`

### 8. Confirm

```
Released vA.B.C — auto-tag workflow running on CI, will tag main + create GitHub Release.
N tickets auto-closed via the release PR.
Drift banner on adopters' forks will fire on next session.
Next: /release-sync vA.B.C
```

### 9. Open the main→dev sync PR (MANDATORY after every release)

Squash-merging dev→main creates SHA divergence: the squash commit on `main` is absent from `dev`, causing the next release PR to accumulate conflicts. Every release must be followed immediately by a sync-back PR.

Invoke:

```
/release-sync vA.B.C
```

This files a `sync/main-to-dev-after-vA.B.C → dev` PR that merges `upstream/main` into `upstream/dev` with `-X ours`, making the squash commit an ancestor of `dev`. The skill is idempotent — if main and dev are already in sync it exits 0 without creating a PR.

**Do not skip this step.** The v2.0.0 release suffered 99 merge conflicts because accumulated sync-back skips were not addressed for multiple release cycles (#403).

## Rules

1. **Framework-only.** Refuse to run on a managed project. The dev/main split is apexyard-the-framework's pattern, not the portfolio's.
2. **Pre-flight every check** in step 1 — never proceed past a dirty tree, missing dev branch, or zero-commit delta.
3. **Always show the bump for confirmation** — auto-detection is a proposal, not a fait accompli. The CEO's eyes are the final check on semver intent.
4. **CHANGELOG is editable** before the release PR opens. Don't auto-file what hasn't been reviewed.
5. **Never auto-merge the release PR.** Rex + CEO approval applies as for any PR. The skill stops at "PR opened."
6. **Never tag before merge, and never tag the release-branch HEAD.** The auto-tag workflow handles tagging after merge, always using `github.sha` (the squash commit). The manual fallback similarly tags `upstream/main`. See step 7 for the full guard.
7. **`<!-- multi-close: approved -->`** in the release PR body is required — release PRs legitimately close many tickets at once.
8. **`--dry-run` stops before writing any files.** The draft CHANGELOG section and PR body are shown; nothing is committed, branched, pushed, or filed.
9. **The `Released-From` trailer must be the PR body's final line, alone in its own paragraph** (AgDR-0094). It is what makes the next release's changelog range deterministic — a trailer that lands mid-body (or gets pushed off the end by later edits) silently degrades back to the pre-AgDR-0094 sync-boundary heuristic, with all its known failure modes (#737, #872).
10. **Show the count-mismatch warning if it fires** — a loud gap between `main..dev`'s raw commit count and the changelog's entry count is the #872 signature. Don't proceed past it without the operator explicitly confirming the range is correct.

## Related

- `AgDR-0007` — the release-cut branch model this skill enacts
- `AgDR-0076` — the automation design record (this enhancement)
- `AgDR-0094` — release provenance via the `Released-From` trailer + count-mismatch guard (#872)
- `bin/release-changelog.sh` — the changelog generation helper script, independently tested
- `docs/release-process.md` — the prose runbook (this skill is the automation; the doc is the manual fallback)
- `.github/workflows/auto-tag-on-release-pr-merge.yml` — the CI workflow that tags the squash commit after merge
- `golden-paths/pipelines/auto-tag-on-release-pr-merge.yml` — the reusable template for managed projects
- `.claude/skills/update/SKILL.md` — the inverse skill, used by adopters pulling new releases into their fork
- `.claude/skills/release-sync/SKILL.md` — the mandatory follow-up skill that syncs main back to dev after every release, preventing squash-divergence accumulation

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

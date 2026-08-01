---
name: release
description: Cut an apexyard release — diff dev↔main, pick semver bump, generate CHANGELOG, open release PR, auto-tag on merge.
argument-hint: "[--dry-run] [<version, e.g. v1.2.0>]"
allowed-tools: Bash, Read, Write
---

# /release — Cut an apexyard release

Standardises the `dev` → `main` release flow introduced by AgDR-0007. Reads the conventional-commit log between `main` and `dev`, proposes a semver bump, **generates and writes the CHANGELOG entry**, **opens the release PR** (dev→main), and triggers the `auto-tag-on-release-pr-merge` GitHub Actions workflow that tags the squash commit and creates a GitHub Release after merge. One command drives the operator from "nothing" to "PR open, ready for Rex + CEO". The tag and GitHub Release entry are created automatically by CI when the PR merges. The release PR also records a `Released-From` trailer with the exact `dev` cut-point SHA, and the changelog step warns loudly if commits inside the resolved changelog range aren't all making it into entries — both guard against the #872 changelog-truncation failure mode. Design rationale: AgDR-0076, AgDR-0094.

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

Call the helper script `bin/release-changelog.sh`, which encapsulates the `git log` + conventional-commit grouping + PR-number extraction logic and is independently tested. Capture both its stdout (the changelog) and stderr (the resolved commit range) — the count-mismatch guard below needs both:

```bash
CHANGELOG_DRAFT=$(PREV_TAG="vX.Y.Z" \
  HEAD_REF="upstream/dev" \
  VERSION="vA.B.C" \
  DATE="$(date +%F)" \
  bash bin/release-changelog.sh 2>/tmp/release-changelog-range.txt)
echo "$CHANGELOG_DRAFT"

# The script also prints the exact range it generated the changelog from —
# trailer-anchored (`<Released-From sha>..HEAD_REF`) when PREV_TAG carries a
# Released-From trailer, or the #737 sync-boundary heuristic otherwise. The
# count-mismatch guard below MUST compare against this range, not main..dev.
LOG_RANGE=$(grep -oE 'RELEASE_CHANGELOG_RANGE=.*' /tmp/release-changelog-range.txt | cut -d= -f2-)

# #1017: fail CLOSED here, not at the arithmetic below. An empty/unparseable
# $LOG_RANGE must stop the release, not silently flow into `git rev-list
# --count ""` (whose stderr never reaches $RAW_COUNT and would let the guard
# read a "0 commits, 0 gap" pass — AgDR-0104: "a gate that can't evaluate its
# precondition must block, not allow").
if [ -z "$LOG_RANGE" ]; then
  echo "ERROR: could not read RELEASE_CHANGELOG_RANGE from bin/release-changelog.sh's stderr (see /tmp/release-changelog-range.txt). The count-mismatch guard has nothing to check against — do NOT proceed until this is resolved." >&2
  exit 1
fi
```

**#1076 — a `Closes` bullet is now emitted ONLY from a recognised, same-repo conventional-commit scope.** `bin/release-changelog.sh` previously (#1056, #1077) resolved an UNSCOPED commit's trailing squash PR number back to the issue it closes via a best-effort `gh pr view --repo <repo>` lookup of the PR's own body. That lookup mechanism (and the `REPO_REMOTE` / `PR_LOOKUP_REPO` env vars that configured it) has been removed entirely: it was itself a source of live wrong closes — a design-doc commit whose subject merely *discussed* several issues could close the wrong one, a cross-repo mention (`other-repo#12`) could be misread as a local issue, and a PR body that merely *mentioned* a closing keyword in prose could resolve to the mentioned number. The governing rule is now "prefer a MISSING close over a WRONG close" (see the script's own header): `fix(#1042): ...` closes `#1042` directly from the scope, with no lookup and no network call; an unscoped commit, a cross-repo scope (`docs(owner/repo#N): ...`), and a revert commit all emit no `Closes` line at all.

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
- Closes #N
- Closes #M
...
```

**#1056 — one bullet per reference, not a comma list.** GitHub's `Closes` keyword only auto-closes the reference *immediately following* it — a single `Closes #N, #M, #P` line only ever closed `#N`; everything after the first was silently inert. The generator now emits one `- Closes #N` bullet per reference so every one of them actually fires. **#1076 narrowed which numbers are eligible in the first place:** a same-repo scoped commit (`fix(#1042): ...`) uses the scope directly (that's the issue, by convention, no lookup needed); everything else — an unscoped commit (`docs: ... (#1045)`), a cross-repo scope (`docs(owner/repo#N): ...`), and a revert commit — emits no `Closes` line at all. A release with fewer `Closes` bullets than before #1076 is expected, not a regression: those refs are now correctly left for a human to close by hand rather than guessed at.

#### Count-mismatch guard (AgDR-0094, option D)

Immediately after generating the draft, sanity-check its entry count against the raw commit count in `$LOG_RANGE` — the **same range `bin/release-changelog.sh` actually built the changelog from**, captured in step 3 above. This is the cheap, always-on backstop behind the `Released-From` trailer (step 4) — it's what caught the v5.0.0 under-count by hand, and it stays even after the trailer exists as defence in depth against a mangled trailer or a trailer-less pre-AgDR-0094 tag.

**#1002 — do not compare against `upstream/main..upstream/dev`.** Under the release-cut model `main` only ever receives squash merges, so every individual `dev` commit stays permanently unreachable from `main` — `main..dev` grows monotonically with every release and can never shrink. Comparing the changelog's entry count against that raw, ever-growing number always false-positives (v5.2.0 cut: 402 raw commits vs. ~1-2 real entries, a "gap" of 400 on a perfectly correct changelog). `$LOG_RANGE` is anchored on the actual cut point (the `Released-From` trailer, or the #737 sync-boundary fallback) and is the range that matters:

**#1017 — what this guard can (and can't) still see.** `RAW_COUNT` and `ENTRY_COUNT` are now *both* derived from the same `$LOG_RANGE`, so the guard can no longer catch a truncated *range* the way it originally did — if `$LOG_RANGE` itself were too narrow, both counts would shrink together and the gap would stay small. That's an acceptable trade, not a silent regression: `$LOG_RANGE`'s anchor is exact by construction once a `Released-From` trailer exists (AgDR-0094), and step 6's post-merge check now makes a missing trailer a hard failure — so the truncated-range case is closed at its source. What the guard genuinely still catches is **classification drop-out inside a correct range**: a commit that really is inside `$LOG_RANGE` but that `bin/release-changelog.sh` didn't turn into a changelog bullet (a subject it failed to classify, a filtering bug, etc.). The warning text below describes that condition, not the old truncated-range one — say what's actually being detected, not what the guard detected before #1012 re-anchored it.

```bash
RAW_COUNT=$(git rev-list --count "$LOG_RANGE") || {
  # #1017: fail CLOSED — don't let a `git rev-list` failure (empty or
  # malformed $LOG_RANGE) leave $RAW_COUNT unset/empty and the arithmetic
  # below silently treat it as 0 (GAP would go negative, no warning, guard
  # passes quiet on exactly the precondition-failure case it exists to catch).
  echo "ERROR: 'git rev-list --count $LOG_RANGE' failed — the count-mismatch guard cannot evaluate its precondition. Do NOT proceed; fix \$LOG_RANGE (see /tmp/release-changelog-range.txt) and rerun." >&2
  exit 1
}
# Count changelog entry bullets, excluding the "- Closes #N" summary bullets
# (#1002: they are a summary, not an entry, and used to be miscounted as one,
# causing an off-by-one on every run; #1056 emits one such bullet PER
# reference instead of a single comma-joined line, so `grep -v` here still
# needs to exclude ALL of them — `-c` already counts non-matching lines, so
# no change to this filter itself was needed, only to this comment).
ENTRY_COUNT=$(printf '%s\n' "$CHANGELOG_DRAFT" | grep -E '^- ' | grep -vcE '^- Closes ' || true)
[ -n "$ENTRY_COUNT" ] || ENTRY_COUNT=0
GAP=$(( RAW_COUNT - ENTRY_COUNT ))
# Tolerance: release/sync/"Merge branch" marker commits are excluded from the
# changelog BY DESIGN (bin/release-changelog.sh's classify step) — a handful
# of those is normal, not a bug. A gap much larger than that means commits
# genuinely inside $LOG_RANGE are failing to classify into changelog entries
# — NOT a truncated range (see the #1017 note above; $LOG_RANGE itself is
# anchored on the Released-From trailer or the #737 fallback either way).
TOLERANCE=5
if [ "$GAP" -gt "$TOLERANCE" ]; then
  echo "⚠️  WARNING: the release range ($LOG_RANGE) has $RAW_COUNT commits but the changelog lists only $ENTRY_COUNT entries (gap: $GAP, tolerance: $TOLERANCE)."
  echo "    Commits inside \$LOG_RANGE are not making it into changelog entries — read 'git log $LOG_RANGE --oneline' against the draft above and find what's missing before proceeding."
fi
```

#### Migration script check (soft, #1105)

Immediately after the changelog draft, check whether this release carries a per-adopter migration script. This is the check `docs/upgrading.md` and `.claude/skills/update/SKILL.md` § 8b have documented since AgDR-0032 but that never actually existed here until #1105 — for 21 consecutive releases nothing flagged the omission, which is exactly how `.claude/migrations/` ended up with scripts for only two of the ~30 release hops it should cover. **This check is advisory only — it warns, it does not block the release.** Making it a hard gate is a larger design decision than this fix covers (see Rule 13 below for why it's deliberately left as a follow-up, not shipped here).

```bash
MIGRATION_SCRIPT=".claude/migrations/${PREV_TAG}-to-vA.B.C.sh"
if [ ! -f "$MIGRATION_SCRIPT" ]; then
  echo "⚠️  WARNING: no migration script found at $MIGRATION_SCRIPT."
  echo "    Every release should ship one — a real migration OR a no-op"
  echo "    placeholder — so /update's per-release migration chain"
  echo "    (.claude/migrations/, walked by _lib-migration-chain.sh) stays"
  echo "    walkable for adopters syncing across this release. See"
  echo "    .claude/migrations/README.md § 'Authoring a new migration'."
  echo "    If this release genuinely needs no adopter action, create the"
  echo "    no-op placeholder now (copy an existing one, e.g."
  echo "    v5.2.0-to-v5.3.0.sh, as the template) before opening the PR."
else
  echo "✓ Migration script present: $MIGRATION_SCRIPT"
fi
```

**Show the draft** (and both warnings, if any) and let the user edit interactively before proceeding. On `--dry-run`, print the draft and stop here with:

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

Refs #<release-ticket>

Released-From: $DEV_SHA"

# Push to upstream (not origin — release PRs target me2resh/apexyard)
git push upstream "release/vA.B.C"
```

**#1004 — the trailer belongs in this commit message, not only the PR body.** The release branch has exactly one commit, so this is the message a squash carries forward by construction — independent of how the merge is invoked. See step 6 for why the PR body copy alone used to silently lose the trailer.

### 5. Open the release PR

```bash
gh pr create \
  --repo me2resh/apexyard \
  --base main \
  --head "release/vA.B.C" \
  --title "release(#<release-ticket>): vA.B.C" \
  --body-file /tmp/release-pr-body.md
```

**PR body template** (write to `/tmp/release-pr-body.md` before the `gh pr create` call). Interpolate `$DEV_SHA` (captured above) into the final line, matching the trailer already written into the branch commit in step 4. This copy is for **human visibility** on the PR page — this repo's `squash_merge_commit_message` setting is `COMMIT_MESSAGES`, so GitHub builds the squash commit's body from the branch's own commit messages, not this PR body, at merge time (#1004). The step-4 commit message is the authoritative copy the squash carries forward; keep this one in sync so a reviewer reading the PR sees the same trailer without having to check the branch commit:

```markdown
<!-- multi-close: approved -->

## Summary

- **Releases vA.B.C** — see CHANGELOG section below for the full list of changes included in this release
- **CHANGELOG.md updated** — new section prepended at the top with grouped feat/fix/chore entries and PR refs
- **Auto-tag on merge** — `.github/workflows/auto-tag-on-release-pr-merge.yml` will tag the squash commit on main and create a GitHub Release entry automatically when this PR merges (AgDR-0076)
- **Release provenance recorded** — a `Released-From` trailer captures the exact `dev` SHA this release was cut from, so the next release's changelog range is deterministic instead of inferred (AgDR-0094, #872)

## CHANGELOG

<paste the draft from step 3>

## Migration script

- [ ] Does this release need a per-adopter migration? A migration script for this release — `.claude/migrations/${PREV_TAG}-to-vA.B.C.sh` (real migration OR no-op placeholder) — is included in this PR, and `docs/upgrading.md`'s "What each migration does" table has a matching row. See `.claude/migrations/README.md`. (Checked automatically by step 3's soft warning — see #1105.)

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

**#1004 — merge with an explicit subject + body, not a bare `gh pr merge --squash`.** This repo has `squash_merge_commit_message=COMMIT_MESSAGES` (`gh api repos/me2resh/apexyard --jq '.squash_merge_commit_message'`), so GitHub's *default* squash body is built from the release branch's own commit messages, not the PR body. Step 4 already writes the `Released-From` trailer into the branch's sole commit, so a bare `gh pr merge --squash` would, in the common case, still carry the trailer through by construction. Don't rely on that alone — pass the reviewed PR body explicitly instead, so the merged commit is guaranteed to match what Rex and the CEO actually reviewed, independent of repo settings, a stray fixup commit changing the branch's commit count, or a future change to `squash_merge_commit_message`:

```bash
gh pr merge <pr-number> --repo me2resh/apexyard --squash \
  --subject "release(#<release-ticket>): vA.B.C" \
  --body-file /tmp/release-pr-body.md
```

`/tmp/release-pr-body.md` is the same file written in step 5 — its final paragraph is already the `Released-From` trailer, so this is the one merge command that keeps the trailer, the changelog, and the reviewed content all in sync on the squash commit.

**Why not just change the repo's `squash_merge_commit_message` setting to `PR_BODY`?** Considered and rejected: that's a repo-wide default that would change the squash body of *every* PR merged to this repo, not just releases — the least-targeted option from #1004's own candidate list. The explicit `--subject`/`--body-file` flags above override the default only for this one merge call, which is exactly the blast radius this fix needs.

**Verify immediately after merge — do not skip:**

```bash
git fetch upstream main
TRAILER=$(git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly)' upstream/main)
if [ -z "$TRAILER" ]; then
  echo "ERROR: squash commit on main has NO Released-From trailer." >&2
  echo "The next release's changelog range will silently fall back to the" >&2
  echo "#737 sync-boundary heuristic. Do not proceed to /release-sync until" >&2
  echo "this is understood — check what merge command was actually used." >&2
  exit 1
fi
echo "Released-From trailer confirmed: $TRAILER"
```

This is the loud-failure the trailer mechanism needs (#1004) — a missing trailer is otherwise invisible until the *next* release cut mis-anchors its range.

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

Verify all four assertions hold (the first three: CI workflow also checks these; the fourth: step 6's verification above, repeated here so it isn't lost if step 6 was skipped):

- [ ] `git merge-base --is-ancestor vA.B.C upstream/main` exits 0
- [ ] `git describe --tags --abbrev=0 upstream/main` returns `vA.B.C`
- [ ] GitHub Release entry exists at `https://github.com/me2resh/apexyard/releases/tag/vA.B.C`
- [ ] `git log -1 --pretty=format:'%(trailers:key=Released-From,valueonly)' vA.B.C` is **non-empty** (#1004) — if empty, STOP before running `/release-sync`; the next release's changelog range will silently degrade to the sync-boundary heuristic

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
9. **The `Released-From` trailer must be its own final paragraph** in BOTH the step-4 branch commit and the step-5 PR body (AgDR-0094). It is what makes the next release's changelog range deterministic — a trailer that lands mid-body (or gets pushed off the end by later edits) silently degrades back to the pre-AgDR-0094 sync-boundary heuristic, with all its known failure modes (#737, #872).
10. **Show the count-mismatch warning if it fires** — a loud gap between `$LOG_RANGE`'s raw commit count and the changelog's entry count means commits inside that range didn't make it into changelog entries (#1017 — not a truncated range; both counts derive from the same `$LOG_RANGE`, so a truncated range can no longer produce this gap). Don't proceed past it without the operator explicitly confirming the range is correct. **Never compare against `upstream/main..upstream/dev`** (#1002) — under the release-cut squash model that range only ever grows, so it always false-positives; `$LOG_RANGE` (captured in step 3) is the range the changelog was actually built from. **A `$LOG_RANGE` that fails to resolve or fails `git rev-list` must halt the release (`exit 1`), never pass silently** (#1017) — see step 3's guard.
11. **Merge the release PR with an explicit `--subject`/`--body-file`, never a bare `gh pr merge --squash`** (#1004) — this repo's `squash_merge_commit_message=COMMIT_MESSAGES` setting silently drops a trailer that lives only in the PR body. See step 6.
12. **Verify the `Released-From` trailer landed on the squash commit immediately after merge, and stop before `/release-sync` if it didn't** (#1004) — a missing trailer is invisible until the *next* release cut silently mis-anchors its changelog range. See step 6's verification block and the post-tag checklist in step 7.
13. **Surface, but don't block on, a missing migration script** (#1105) — step 3's migration-script check and the PR body's "Migration script" checkbox are both **advisory**. This is deliberate, not an oversight: whether a release needs an adopter-facing migration is a judgement call (does this release actually change anything an adopter's fork needs to react to?), and a hard-blocking gate would force every doc-only or internal-tooling release to manufacture a no-op script just to pass CI. Making it a blocking gate (a pre-push hook, or a required PR-create check) is a larger design decision — deliberately left as a follow-up, not bundled into #1105's fix. Until then, the discipline is: read the warning, decide honestly, and don't skip past it out of habit — that's exactly the discipline gap that let 21 consecutive releases ship with no migration script at all.

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

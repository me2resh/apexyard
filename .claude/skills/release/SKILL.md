---
name: release
description: Cut an apexyard release — diff dev↔main, pick semver bump, generate CHANGELOG, open release PR, tag + push after merge.
argument-hint: "<optional explicit version, e.g. v1.2.0>"
allowed-tools: Bash, Read, Write
---

# /release — Cut an apexyard release

Standardises the `dev` → `main` release flow introduced by AgDR-0007. Reads the conventional-commit log between `main` and `dev`, proposes a semver bump, generates a CHANGELOG entry, opens the release PR, and (after the user merges) tags the resulting commit and pushes the tag.

This skill is **framework-only** — it's for cutting apexyard releases, not for releasing managed projects under governance. Managed projects stay trunk-based and don't have a release-cut flow.

## Usage

```
/release             # auto-detect bump from conventional commits
/release v1.2.0      # explicit version, skip auto-detect
/release --dry-run   # preview only, don't create the PR
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

Otherwise auto-detect from the conventional-commit types in `git log main..upstream/dev`:

| Found | Bump |
|-------|------|
| Any commit subject starts with `feat!:` / `feat(...)!:` / `<type>!:` (breaking marker) | **MAJOR** |
| Any `feat:` / `feat(...):` (and no breaking) | **MINOR** |
| Only `fix:` / `chore:` / `docs:` / `refactor:` / `test:` / `style:` / `perf:` / `build:` / `ci:` (and no `feat:` or breaking) | **PATCH** |

Read the current latest tag (`git describe --tags --abbrev=0 main` or `gh api repos/me2resh/apexyard/releases/latest`) and bump accordingly. Show the user:

```
Current latest tag: vX.Y.Z
Proposed next:      vA.B.C  (MINOR — N feat commits, M fix commits)
Override? [Enter to accept, or type a version like v1.3.0]
```

### 3. Generate the CHANGELOG draft

Run `git log <prev-tag>..upstream/dev --pretty=format:'%h %s'` and group by conventional-commit type:

```markdown
## vX.Y.Z — YYYY-MM-DD

### Added (feat)
- (#NN) <subject> — <short-sha>
- ...

### Fixed (fix)
- (#NN) <subject> — <short-sha>

### Changed (refactor / chore / docs)
- (#NN) <subject> — <short-sha>

### Breaking
- <only if breaking-marker commits exist>

### Closes
- <enumerate every `Closes #N` from PR bodies merged to dev since last tag>
```

Show the draft and let the user edit interactively before opening the PR.

### 3.5. Bump the marketing-site version strings (`site/index.html`)

The marketing site hard-codes the framework version in several places. `/release`
bumps the git tag + CHANGELOG but historically did NOT touch these, so they
drifted across ~5 release cycles before anyone noticed (#491 / #493). Update them
**in the same commit that lands the CHANGELOG entry**, driven by the version being
cut (`vX.Y.Z`, with `X.Y.Z` the bare semver and `X.Y` the major.minor) and the
release date (`YYYY-MM-DD`):

| Location in `site/index.html` | What to set | Approx. line |
|------|------|------|
| JSON-LD `softwareVersion` | `X.Y.Z` (no `v` prefix — matches CHANGELOG `## [X.Y.Z]`) | ~L54 |
| JSON-LD `dateModified` | release date `YYYY-MM-DD` | ~L57 |
| Hero pill `apexyard vX.Y` | `apexyard vX.Y` | ~L1568 |
| Hero version link **text** | `vX.Y.Z` | ~L1576 |
| Hero version link **href** | `…/releases/tag/vX.Y.Z` | ~L1576 |
| Releases-shipped metric **count** | number of `## [` release entries in `CHANGELOG.md` | ~L1696 |
| Releases-shipped metric **range** | `(v0.1 → vX.Y)` | ~L1696 |

Derive every value from the version being cut — do not hand-pick. Suggested
computation:

```bash
VER="${VERSION#v}"                       # 2.2.0  (strip leading v if present)
MAJOR_MINOR="${VER%.*}"                   # 2.2
RELEASE_DATE=$(date +%F)                  # YYYY-MM-DD (or the CHANGELOG entry's date)
RELEASE_COUNT=$(grep -cE '^## \[[0-9]' "$ops_root/CHANGELOG.md")  # count of release entries
```

**Leave historical version strings untouched** — CHANGELOG entries, migration-script
filenames (e.g. `migrate-v1-to-v2.ts`), and AgDR examples that quote an old version
are history, not the current-version advertisement. Only the seven locations above
move with each cut.

Show the resulting `site/index.html` diff alongside the CHANGELOG diff in the
dry-run / preview so the operator sees both before the PR opens.

> **Durable guard:** `test_site_counts.sh` asserts `site/index.html`'s JSON-LD
> `softwareVersion` equals the top-most `## [X.Y.Z]` entry in `CHANGELOG.md`, and
> the CI workflow `site-counts-check.yml` runs it on every PR. If you bump the
> CHANGELOG without bumping the site (or vice-versa), CI goes red — the drift can
> no longer accumulate silently.

### 4. Open the release PR

Branch from `dev`: `release/vA.B.C`. Push to `upstream`. Open PR:

- **Base**: `main`
- **Head**: `release/vA.B.C`
- **Title**: `release(#<release-ticket>): vA.B.C` — e.g. `release(#160): v1.2.0`. The release-cut ticket (filed via the standard ticket flow) is the natural scope, and `release` was added to the `pr.title_type_whitelist` in #168 so this title shape passes `validate-pr-create.sh` like every other PR title.
- **Body**: the CHANGELOG draft + an explicit "this PR will tag `vA.B.C` on `main` after merge"

The PR body should aggregate every `Closes #N` from the included commits so that merging the release PR auto-closes all of them on GitHub at once.

Skip-marker note: the release PR's body legitimately has many `Closes #N`. The hook from #114 (single-Closes-per-PR) will block it. Use `<!-- multi-close: approved -->` to bypass — release PRs are exactly the umbrella case the marker is designed for.

### 5. Wait for review + merge

The release PR runs through the normal flow:

- Code Reviewer (Rex) on the PR
- CEO `/approve-merge`
- Merge gate green
- Squash-merge to `main`

`/release` does not auto-merge. The CEO retains the discrete moment.

### 6. Tag + push (after merge)

Once the release PR merges, the user invokes `/release --tag vA.B.C` (or runs the suggested commands manually):

```bash
git fetch upstream main
git tag vA.B.C upstream/main
git push upstream vA.B.C
```

### 7. Optional: GitHub Release

If the user wants a Release entry on GitHub:

```bash
gh release create vA.B.C \
  --repo me2resh/apexyard \
  --title "vA.B.C" \
  --notes-file <changelog-section>
```

The CHANGELOG section from step 3 is the body.

### 8. Confirm

```
Released vA.B.C — tag pushed to upstream/main.
N tickets auto-closed via the release PR.
Drift banner on adopters' forks will fire on next session.
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
6. **Never tag before merge.** Tags follow the merge commit on `main`, not the dev HEAD.
7. **`<!-- multi-close: approved -->`** in the release PR body is required — release PRs legitimately close many tickets at once.

## Related

- `AgDR-0007` — the decision record this skill enacts
- `docs/release-process.md` — the prose runbook (this skill is the automation; the doc is the manual fallback)
- `.claude/skills/update/SKILL.md` — the inverse skill, used by adopters pulling new releases into their fork
- `.claude/skills/release-sync/SKILL.md` — the mandatory follow-up skill that syncs main back to dev after every release, preventing squash-divergence accumulation

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

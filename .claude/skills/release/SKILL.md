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

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

# apexyard release process

apexyard uses a **release-cut** branch model (sometimes called gitflow-lite) for the framework repo. This doc is the prose runbook for cutting a release. The `/release` skill at `.claude/skills/release/SKILL.md` automates most of the steps; this doc is the manual fallback and the conceptual reference.

**Important — framework only.** This release model is for `me2resh/apexyard` itself, not for managed projects under apexyard governance. Managed projects stay trunk-based (PRs merge to `main`); only the framework has dev/main + tags. See `docs/multi-project.md` for the rationale.

Decision records: [`docs/agdr/AgDR-0007-release-cut-branch-model.md`](agdr/AgDR-0007-release-cut-branch-model.md) · [`docs/agdr/AgDR-0076-release-automation.md`](agdr/AgDR-0076-release-automation.md).

## Branch model

```
dev  ──●──●──●──●──●──●──────●──●──────●──●──────  (daily work; PRs land here)
        \                    /          /
         \                  /          /
main ─────●────────────────●──────────●──────────────  (released only; tagged on each merge)
          v1.1.0           v1.2.0    v1.2.1
```

- **`dev`** — every feature/fix/chore PR targets here. All hooks + review gates apply unchanged.
- **`main`** — only receives merges from `dev`, via release PRs. Every merge to `main` is tagged with a semver. Direct pushes blocked by `block-main-push.sh`.
- Releases are `dev → main` squash-merges, tagged `vX.Y.Z` automatically by CI after merge.
- No `release/*` branches (no stabilisation window needed for docs+hooks).
- No `hotfix/*` branches (no multi-version support; forks always run latest).

## When to cut a release

Curated cadence — release when there's a meaningful batch on `dev` that's worth surfacing to adopters. Loose guidance:

- **Patch (`vX.Y.Z+1`)** — bug fixes only. Cut whenever there are ≥ 1 fix and adopters would benefit.
- **Minor (`vX.Y+1.0`)** — new features (additive). Cut every 1–2 weeks if there's been net-new feature work.
- **Major (`vX+1.0.0`)** — breaking changes. Coordinate with adopters first; release notes call out migrations.

If `dev` is N commits ahead and nothing's broken, you're free to NOT release — adopters will stay on the previous tag and the drift banner will tell them about the new tag when it's cut.

## Cutting a release — happy path (automated)

Run `/release` for the full guided, automated flow:

```
/release             # auto-detect bump from conventional commits
/release v1.2.0      # explicit version
/release --dry-run   # preview changelog + PR body without writing any files
```

The skill:

1. Pre-flights the repo (clean tree, dev branch, non-empty delta)
2. Auto-detects the semver bump from conventional commits (or accepts explicit version)
3. Calls `bin/release-changelog.sh` to generate the CHANGELOG section (independently testable helper)
4. Shows the draft for review / editing
5. Writes `CHANGELOG.md` (prepends the new section)
6. Creates the release branch `release/vX.Y.Z` from dev, commits, and pushes
7. Opens the release PR (dev→main) with the CHANGELOG section as body
8. Stops at PR creation — CEO approval gate remains the sole human gate

After the PR merges, the `auto-tag-on-release-pr-merge.yml` CI workflow fires and:

- Tags the squash commit on `main` (using `github.sha` — always the correct commit, never the branch HEAD)
- Runs the ancestry guard (`git merge-base --is-ancestor <sha> main`)
- Creates a GitHub Release entry from the CHANGELOG section in the PR body (in the same job — a tag pushed via GITHUB_TOKEN does not trigger a secondary release workflow)

Then run `/release-sync vX.Y.Z` to sync main→dev and prevent squash-divergence accumulation.

## Cutting a release — manual steps (fallback)

If `/release` is unavailable or if you need to debug a release, run the steps manually:

```bash
# 1. Verify pre-conditions
git fetch upstream
git rev-parse upstream/main upstream/dev    # both should resolve
git log upstream/main..upstream/dev --oneline | head    # should be non-empty

# 2. Pick the version
PREV_TAG=$(git describe --tags --abbrev=0 upstream/main)
# e.g. PREV_TAG=v3.2.0, so next is v3.3.0 (minor bump because of feat: commits)
VERSION=v3.3.0

# 3. Generate the CHANGELOG section
PREV_TAG="$PREV_TAG" HEAD_REF="upstream/dev" VERSION="$VERSION" DATE="$(date +%F)" \
  bash bin/release-changelog.sh > /tmp/changelog-section.md
# Review and edit /tmp/changelog-section.md

# 4. Prepend to CHANGELOG.md
cat /tmp/changelog-section.md CHANGELOG.md > /tmp/cl_new.md
mv /tmp/cl_new.md CHANGELOG.md

# 5. Cut release branch from dev
git checkout -b "release/$VERSION" upstream/dev
git add CHANGELOG.md
git commit -m "chore: release $VERSION"
git push upstream "release/$VERSION"

# 6. Open release PR
gh pr create \
  --repo me2resh/apexyard \
  --base main \
  --head "release/$VERSION" \
  --title "release(#<ticket>): $VERSION" \
  --body-file /tmp/release-pr-body.md
# Add <!-- multi-close: approved --> to the body

# 7. Run normal review flow on the PR
#    - /code-review
#    - /approve-merge <pr>
#    - gh pr merge <pr> --squash

# 8. After merge: CI auto-tags (auto-tag-on-release-pr-merge.yml)
#    If CI fails, tag manually:
git fetch upstream main
git tag "$VERSION" upstream/main
if ! git merge-base --is-ancestor "$VERSION" upstream/main; then
  echo "ERROR: tag is mis-placed" >&2; exit 1
fi
# Use --tags not the bare tag name (avoids branch-name validator hook misfiring)
git push upstream --tags

# 9. Run release-sync
# /release-sync $VERSION
```

## Release PR caveats

The release PR's body legitimately contains many `Closes #N` references — every ticket that landed on `dev` since the last release. The single-Closes-per-PR check from #114 will block the open. Add the skip marker to the body:

```
<!-- multi-close: approved -->
```

The marker is grep-able on purpose; release PRs are exactly the umbrella case it's designed for.

## Auto-tag workflow

The `.github/workflows/auto-tag-on-release-pr-merge.yml` workflow fires when any PR with a `release/v*` head branch is merged to `main`. It:

- Extracts the version from the head branch name
- Uses `github.sha` (the squash commit SHA) — always the correct commit, never the release-branch HEAD (which was discarded by the squash)
- Runs `git merge-base --is-ancestor <sha> main` before tagging
- Tags and pushes with `git push origin --tags` (not the bare tag name — avoids the branch-name validator hook misfiring)
- Creates a GitHub Release entry in the same job (a tag pushed via GITHUB_TOKEN does not trigger a secondary release workflow — confirmed in apexyard-premium#326)

This closes the v2.3.0 incident where the tag was placed on the release-branch HEAD rather than the squash commit.

A golden-path copy lives at `golden-paths/pipelines/auto-tag-on-release-pr-merge.yml` for adopters who want the same pattern on managed projects.

## Changelog generation

The `bin/release-changelog.sh` helper encapsulates the changelog-from-commits logic:

```bash
PREV_TAG=v3.2.0 HEAD_REF=upstream/dev VERSION=v3.3.0 DATE=$(date +%F) \
  bash bin/release-changelog.sh
```

Input: `PREV_TAG`, `HEAD_REF`, `VERSION`, `DATE` env vars.
Output: markdown CHANGELOG section to stdout.
Never writes files; callers decide where to write the output.
Tests: `.claude/hooks/tests/test_release_changelog.sh`.

## Drift banner behaviour

After a release tag is pushed, every fork's `check-upstream-drift.sh` hook (tag-based since v1.1.0) prints a banner on next session:

```
ApexYard: v1.2.0 available. Run /update to sync.
```

`/update` pulls `upstream/main` into the fork's main — which now contains only the released content.

## Hotfix path (not implemented; revisit if needed)

apexyard does NOT have a hotfix flow today. If a critical bug ships in `vX.Y.Z` and adopters need a fix without waiting for the next normal release, the workaround:

1. Cut a normal `dev → main` release with just the fix (a `vX.Y.Z+1` patch).
2. Release within hours rather than days; cadence is the only difference.

If multi-version maintenance becomes a real need (e.g. some adopters can't upgrade past `v1.x.x`), revisit AgDR-0007 with a new options table — full git flow's `hotfix/*` and `support/*` patterns become relevant.

## Branch protection (manual GitHub setting)

For maintainers of `me2resh/apexyard`, configure GitHub branch protection on `main`:

- Require pull request before merging
- Require approvals: 1
- Require status checks to pass before merging (markdownlint, lychee, shellcheck, Verify Ticket ID)
- Restrict who can push to matching branches (only repo admins, for the rare manual tag-fix case)

Branch protection on `dev` matches the prior `main` setup — required reviews + required checks.

## Related

- `AgDR-0007` — the original release-cut branch model decision record
- `AgDR-0076` — the release-automation design record
- `.claude/skills/release/SKILL.md` — the automated flow (this doc is the manual fallback)
- `bin/release-changelog.sh` — the changelog generation helper
- `.github/workflows/auto-tag-on-release-pr-merge.yml` — the auto-tag CI workflow
- `golden-paths/pipelines/auto-tag-on-release-pr-merge.yml` — the reusable golden-path copy
- `.claude/skills/update/SKILL.md` — the inverse skill, for adopters pulling new releases
- `.claude/skills/release-sync/SKILL.md` — the mandatory main→dev sync after every release
- `docs/multi-project.md § "Upgrades — pulling from upstream"` — adopter side of the relationship

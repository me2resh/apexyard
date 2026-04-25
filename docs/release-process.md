# apexyard release process

apexyard uses a **release-cut** branch model (sometimes called gitflow-lite) for the framework repo. This doc is the prose runbook for cutting a release. The `/release` skill at `.claude/skills/release/SKILL.md` automates most of the steps; this doc is the manual fallback and the conceptual reference.

**Important — framework only.** This release model is for `me2resh/apexyard` itself, not for managed projects under apexyard governance. Managed projects stay trunk-based (PRs merge to `main`); only the framework has dev/main + tags. See `docs/multi-project.md` for the rationale.

Decision record: [`docs/agdr/AgDR-0007-release-cut-branch-model.md`](agdr/AgDR-0007-release-cut-branch-model.md).

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
- Releases are `dev → main` merge commits, tagged `vX.Y.Z`.
- No `release/*` branches (no stabilisation window needed for docs+hooks).
- No `hotfix/*` branches (no multi-version support; forks always run latest).

## When to cut a release

Curated cadence — release when there's a meaningful batch on `dev` that's worth surfacing to adopters. Loose guidance:

- **Patch (`vX.Y.Z+1`)** — bug fixes only. Cut whenever there are ≥ 1 fix and adopters would benefit.
- **Minor (`vX.Y+1.0`)** — new features (additive). Cut every 1–2 weeks if there's been net-new feature work.
- **Major (`vX+1.0.0`)** — breaking changes. Coordinate with adopters first; release notes call out migrations.

If `dev` is N commits ahead and nothing's broken, you're free to NOT release — adopters will stay on the previous tag and the drift banner will tell them about the new tag when it's cut.

## Cutting a release — happy path

Use `/release` for the full guided flow. Manual steps for reference:

```bash
# 1. Verify pre-conditions
git fetch upstream
git rev-parse upstream/main upstream/dev    # both should resolve
git log upstream/main..upstream/dev --oneline | head    # should be non-empty

# 2. Pick the version (e.g. v1.2.0 — minor bump because of feat: commits)

# 3. Cut release branch from dev
git checkout -b release/v1.2.0 upstream/dev
git push upstream release/v1.2.0

# 4. Open release PR
gh api repos/me2resh/apexyard/pulls -X POST \
  -f title="release: v1.2.0" \
  -f body-file=/tmp/changelog-v1.2.0.md \
  -f head="release/v1.2.0" \
  -f base="main"

# 5. Run normal review flow on the PR
#    - Code Reviewer (Rex)
#    - /approve-merge <pr>
#    - gh pr merge <pr> --squash

# 6. After merge: tag main + push the tag
git fetch upstream main
git tag v1.2.0 upstream/main
git push upstream v1.2.0

# 7. Optional: GitHub Release entry
gh release create v1.2.0 \
  --repo me2resh/apexyard \
  --title "v1.2.0" \
  --notes-file /tmp/changelog-v1.2.0.md
```

## Release PR caveats

The release PR's body legitimately contains many `Closes #N` references — every ticket that landed on `dev` since the last release. The single-Closes-per-PR check from #114 will block the open. Add the skip marker to the body:

```
<!-- multi-close: approved -->
```

The marker is grep-able on purpose; release PRs are exactly the umbrella case it's designed for.

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

- `AgDR-0007` — the decision record
- `.claude/skills/release/SKILL.md` — the automated flow
- `.claude/skills/update/SKILL.md` — the inverse skill, for adopters pulling new releases
- `docs/multi-project.md § "Upgrades — pulling from upstream"` — adopter side of the relationship

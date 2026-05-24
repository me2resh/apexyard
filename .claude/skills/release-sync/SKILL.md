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
3. Open a test release PR from dev → main — confirm only new work appears in the diff

Refs #403

---

## Glossary

| Term | Definition |
|------|------------|
| Squash divergence | When a release PR is squash-merged to main, the resulting commit has a different SHA than the equivalent dev history, so dev still carries the un-squashed commits as "unsynced" |
| `-X ours` | Git merge strategy option that resolves conflicts in favour of "our" side — when on a dev-based branch merging main, "ours" = dev, which is correct because dev already has the un-squashed equivalents |
| `sync/main-to-dev-after-<version>` | Short-lived branch used to carry the merge commit from main into dev; deleted after the PR merges |
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

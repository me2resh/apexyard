# Sync PRs must use --merge (true merge), not --squash

> In the context of the apexyard `/release-sync` skill (AgDR-0052), facing
> the discovery that the v2.2.0 sync PR was squash-merged — silently destroying
> the ancestry link the skill was designed to create — I decided to
> (a) auto-detect sync-class PRs in `/approve-merge` and use `--merge`
> automatically, and (b) add a guard in `block-unreviewed-merge.sh` that
> refuses `--squash` on `sync/`-prefixed PRs, accepting the trade-off that
> this is a special case in two previously-general components.

## Context

The `/release-sync` skill (introduced in apexyard#403, documented in AgDR-0052)
fixes squash-divergence by branching from `upstream/dev`, running
`git merge --no-ff -X ours upstream/main`, and opening a PR. The merge commit
produced by that operation has **two parents**:

1. The dev branch head (first parent — the branch this is on)
2. The release squash commit on main (second parent — what was merged in)

The second parent relationship is what makes
`git merge-base --is-ancestor <release-squash> dev` return true. That
ancestry link is the entire value of the skill: once it holds, future
`dev → main` release PRs only show genuinely-new commits in the diff.

However, during the release that followed the introduction of `/release-sync`,
the sync PR was merged with `--squash` (the `/approve-merge` default). Squash
collapses the two-parent merge commit into a single-parent commit. The second
parent is permanently discarded.

Post-merge verification confirmed the breakage:

```
git merge-base --is-ancestor <release-squash> upstream/dev  →  false
git log upstream/dev..upstream/main --oneline               →  still N commits
```

Dev got main's *content* (the CHANGELOG carry-forward worked correctly) but the
release squash is not an ancestor of dev. The next release PR will re-encounter
the squash-divergence conflicts the skill was designed to prevent.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. Add `--merge-strategy <merge\|squash\|rebase>` flag to `/approve-merge`** | General-purpose; operator picks per PR | Requires operator to remember to pass `--merge` for every sync PR; the v2.2.0 incident shows this is the failure mode we're solving — operator ceremony isn't a reliable safeguard |
| **B. Auto-detect sync-class PRs in `/approve-merge`, use `--merge` automatically** | Correct by default; operator can't forget; no new flag surfaces | Special-case in a previously-general skill; detection is heuristic (branch prefix + title prefix) |
| **C. Change the default in `/approve-merge` from `--squash` to `--merge`** | No special case | Breaking change for all non-sync PRs; the framework documents squash-merge as the release model; adopters who prefer squash for clean `main` history would be affected |

For the guard:

| Option | Pros | Cons |
|--------|------|------|
| **D. Guard in `block-unreviewed-merge.sh` refusing `--squash` on sync PRs** | Mechanical backstop; fires on both `gh pr merge` and `gh api` shapes; catches direct CLI merges, not just `/approve-merge` invocations | Special-case in a previously-general hook; requires a GitHub API call (same gh call as the existing SHA resolution) |
| **E. Guard in `/approve-merge` only (no hook change)** | Simpler; no hook change needed | Does not prevent a direct `gh pr merge <sync-pr> --squash` invocation that bypasses the skill entirely |
| **F. No guard; rely on documentation only** | Zero added complexity | The v2.2.0 incident shows documentation alone doesn't prevent this; the failure mode is silent and hard to notice until the next release PR hits divergence |

## Decision

Chosen: **Option B (auto-detect in `/approve-merge`) + Option D (guard in hook)**.

**B** because:

1. The failure mode is silent — the merge succeeds, the branch is deleted, and the breakage is only visible weeks later at the next release. A purely-flag approach puts the safety entirely on operator memory.
2. The detection heuristic is stable: `sync/main-to-dev-after-` is the canonical branch prefix documented in the SKILL.md; `sync(` is the canonical PR title prefix. Neither will change without a deliberate update to the skill.
3. Surfacing the strategy in the merge report (`strategy: --merge, auto-detected sync PR`) makes the behaviour visible without adding friction.

**D** because:

1. Option B only covers merges via `/approve-merge`. A developer or automation that runs `gh pr merge <sync-pr> --squash` directly bypasses the skill and re-introduces the bug silently.
2. The guard reuses the same `gh pr view` call already present in the hook for SHA resolution, so the incremental cost is low.
3. The guard's error message explains the rationale and the correct command, so it's educational rather than just blocking.

Option A (flag) is rejected because it converts a safety requirement into optional operator ceremony — the exact failure mode this fix targets. It could be added later as an opt-in override for unusual cases, but the default must be safe-by-default.

**Merge strategy terminology clarification:**

There are two independent merge strategies in play and they must not be confused:

| Where | Strategy | Meaning |
|-------|----------|---------|
| Step 5 of `/release-sync` (building the sync branch) | `-X ours` | When running `git merge upstream/main` to build the sync branch, dev content wins on conflicts. This is about *conflict resolution during the local branch build*. |
| Step 7 (merging the sync PR into dev) | `--merge` (true merge) | When merging the sync PR via GitHub, use a true merge commit (not squash). This is about *how the PR is merged into dev*. |

These are orthogonal. `-X ours` is correct and unchanged. `--merge` is the new requirement being added here.

## Consequences

- `/approve-merge` auto-uses `--merge` for any PR whose head branch starts with
  `sync/main-to-dev-after-` or whose title starts with `sync(`. For all other
  PRs the default remains `--squash`. The strategy used is surfaced in the
  merge report.
- `block-unreviewed-merge.sh` blocks `--squash` and `--rebase` on `sync/main-to-dev-after-*`
  PRs on both the `gh pr merge` and `gh api .../pulls/<N>/merge` shapes. Network
  failure on the `gh pr view` branch-lookup falls back to "skip guard" (don't
  block the merge) rather than "block all syncs" — availability beats strict
  enforcement on an ephemeral check.
- A test in `test_block_unreviewed_merge.sh` covers: sync PR + `--squash` → blocked;
  sync PR + `--merge` + valid markers → passes; non-sync PR + `--squash` + valid
  markers → still passes (guard is narrowly scoped).

## Residual state — recent release divergence

The v2.2.0 sync PR was squash-merged before this fix. Dev currently has main's
content but the v2.2.0 squash commit (`3584059`) is not an ancestor of dev.

**Recommendation**: run `/release-sync` again at the next release using this
fixed flow. The `-X ours` strategy will cleanly resolve the content-identical
conflicts (dev and main agree on content, so there are no real conflicts), and
the `--merge` PR merge will close the ancestry gap. The cost is one extra
round of conflict resolution at the next release.

An alternative is a one-off ancestry-repair merge on dev now (before the next
release), but this is an externally-visible change to a shared branch and
warrants explicit operator sign-off. The recommendation above — absorb it at
next release — is lower-risk and requires no out-of-band intervention.

## Artifacts

- `.claude/skills/release-sync/SKILL.md` — step 7 expanded with merge-strategy requirement + rationale; rule 5 updated; AgDR-0053 referenced
- `.claude/skills/approve-merge/SKILL.md` — step 6 (sync detection) and step 7 (merge command) updated; step 8 report updated; AgDR-0053 referenced
- `.claude/hooks/block-unreviewed-merge.sh` — sync-PR squash guard added after PR-number extraction
- `.claude/hooks/tests/test_block_unreviewed_merge.sh` — three new cases covering the guard
- Implementing ticket: `me2resh/apexyard#459`

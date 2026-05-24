# Add /release-sync skill to reconcile dev/main squash divergence after each release

> In the context of the apexyard release-cut branch model (AgDR-0007), facing a compounding squash divergence that produced 99 merge conflicts on the v2.0.0 release PR, I decided to introduce a `/release-sync` skill invoked explicitly as the final step of `/release`, accepting that the sync requires a PR that goes through the normal Rex + CEO approval gate rather than running automatically.

## Context

- The apexyard release flow squash-merges `dev → main` on every release (AgDR-0007). Each squash creates a SHA divergence: the squash commit on `main` has a different SHA than the equivalent un-squashed commits on `dev`, so `dev` still carries those commits as "unsynced" history.
- Over multiple releases the gap accumulates: by v2.0.2, there were 6 squash commits on `main` not present on `dev`.
- The v2.0.0 release PR suffered 99 conflicts caused by this accumulation. v2.0.1 + v2.0.2 worked around the problem by cherry-picking directly from `main`, but that only works for single-commit releases.
- The fix direction is a `main → dev` merge with `-X ours` (dev wins on conflicts, which is correct because dev already has the un-squashed equivalents). This makes the squash commits ancestors of `dev`, so future `dev → main` release PRs only see genuinely-new commits.
- Three fix candidates were evaluated (see #403 Mitigation section): explicit skill, branch protection rule, and switching from squash to merge-commit. The skill approach is lowest friction and compatible with the existing release flow.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **A. `/release-sync` skill — explicit, final step of `/release`** | Low friction; integrates into existing release ritual; idempotent; operator can review the sync PR; no new automation dependencies | Requires operator to remember the extra step; one PR per release lifecycle |
| **B. Auto-invoke `/release-sync` from within `/release` (no separate step)** | Zero operator ceremony — release automatically opens the sync PR | Adds two PRs to every release (release PR + sync PR) in a single skill invocation; harder to skip if not needed; mixes concerns in a single skill turn |
| **C. Switch from squash-merge to merge-commit on release PRs** | Eliminates divergence at source — no bookkeeping merge needed | Breaking change to release PR ergonomics; `main` log becomes noisier (all dev commits appear); requires branch protection rule changes; bigger framework decision with adopter-visible effects |
| **D. Branch protection "must be ancestor of dev" rule** | Mechanically enforced | Incompatible with squash-merge by design — squash never creates an ancestor relationship; effectively a non-starter |

## Decision

Chosen: **Option A (explicit `/release-sync` skill, final step of `/release`)**, because:

1. **Least friction** — the skill pattern is already established in the framework; operators know how it works.
2. **Preserves the discrete merge-gate moment** — the sync PR goes through Rex + CEO approval, same as any PR. This is deliberate: the sync merge commit touches dev HEAD and should be reviewed, even if it's a bookkeeping operation.
3. **Idempotent and safe** — if main and dev are already in sync, the skill exits 0 without creating a PR. Running it twice is harmless.
4. **Explicit over implicit** — Option B (auto-invoke) hides the sync inside `/release`, making the two-PR release lifecycle less visible. Explicit invocation makes the ceremony auditable.

Option C (merge-commit instead of squash) was considered carefully. It eliminates the problem at the source but changes the `main` branch's log in ways that affect adopters (they see every dev commit in `git log main`). That's a bigger architectural change than this issue warrants; it can be reconsidered as a separate AgDR if the team decides the tradeoff is worth it.

**Merge strategy direction:**

When `/release-sync` creates a sync branch from `upstream/dev` and runs `git merge upstream/main`:

- `-X ours` = our branch (dev-based) wins conflicts — **correct choice**
- `-X theirs` = incoming (main's squash commit) wins conflicts — wrong; would overwrite dev's un-squashed equivalents with the squash


The common confusion is that the issue description (#403) initially frames this as "dev wins" and associates it with `-X theirs`, but that framing is from the wrong perspective. In git merge semantics: "ours" = the branch you're on when you run `git merge`; "theirs" = the branch you're merging in. Since we branch from dev and merge main, "ours" = dev = the correct winner.

## Consequences

- Every `/release` invocation should be followed by `/release-sync vX.Y.Z` to file the sync PR. The `/release` SKILL.md is updated to document Step 9 as mandatory.
- The sync PR is short-lived (branch `sync/main-to-dev-after-vX.Y.Z`), goes through the normal gate, and is deleted after merge.
- If the sync step is skipped for a release, the divergence accumulates silently — the same root cause as before. The skill being explicit (not automatic) means operator discipline is still required.
- The skill is idempotent: if already in sync (e.g. because the release was a no-squash merge or the sync was done manually), it exits 0 without creating a PR.
- Framework-only guard: the skill refuses to run on managed projects, same as `/release`.

## Artifacts

- `.claude/skills/release-sync/SKILL.md` — new skill implementation
- `.claude/skills/release/SKILL.md` — updated to document Step 9 (invoke `/release-sync`)
- `.claude/hooks/tests/test_release_sync.sh` — smoke tests for the sync branch/PR shape
- Implementing ticket: `me2resh/apexyard#403`

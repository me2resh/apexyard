# v5.4.0 ships a real migration untracking `project-config.json`

> In the context of cutting the v5.4.0 release, facing the fact that #1065 fixed the `project-config.json` tracking-vs-ignore data-loss bug only on the framework side, I decided to ship a **real** per-adopter migration (`v5.3.0-to-v5.4.0.sh`) that untracks the file on adopter forks, to achieve close the same data-loss window everywhere it exists, accepting that the migration mutates adopter git state and so needs a careful, idempotent, non-forcing guard.

## Context

The last four release hops (`v4.4.0`→`v5.3.0`) are all no-op placeholders backfilled by #1105. v5.4.0 is different: it carries the adopter-side completion of **#1065**.

What #1065 found: `.gitignore` listed `.claude/project-config.json`, but the file was **also tracked in the index**, and git ignores `.gitignore` for already-tracked files — so the ignore rule was inert on every adopter fork. Because the file was tracked, a plain `git checkout <branch>` silently overwrites the working copy with the indexed version. For a split-portfolio adopter that destroys the private `portfolio` block, which is config-only (no convention-based sibling discovery) and never committed to git, so it is unrecoverable. This happened on a real fork.

In #1065 the **framework** repo was fixed (untracked the file, shipped a tracked `project-config.example.json`). But an adopter sitting on v5.3.0 still has the file tracked in **their own** fork — the data-loss window stays open for them until the file is untracked there too. A framework-side untrack does not propagate to an adopter's index through a normal sync (modify/delete merge semantics are unreliable here), so the release needs an explicit migration.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| A — No-op placeholder (like the last 4 hops) | Simplest; zero risk of touching adopter state | Leaves the #1065 data-loss window open on every adopter fork; the release-time migration check would pass on an empty promise |
| B — Real migration: `git rm --cached` the file on the adopter fork, idempotent, defer-not-force | Closes the window during the `/update` flow the adopter already runs; preserves working-tree content; safe guard | Mutates adopter git state — needs a correct guard so it never touches an already-untracked file or forces past an unexpected staged state |
| C — Rely on merge semantics + the SessionStart `check-git-hooks-installed`-style advisory only | No migration script to write | Merge semantics for modify/delete are unreliable; no advisory exists for this file; leaves the fix to chance |

## Decision

Chosen: **Option B**, because the data-loss window is real and only the adopter's own fork can close it, and `/update`'s migration chain is exactly the mechanism designed to apply a per-release adopter-side change. The script:

- Guards on "currently tracked" (`git ls-files --error-unmatch`) — a no-op if already untracked.
- Runs `git rm --cached`, leaving the working-tree file and the adopter's customisations in place.
- Stages the untrack rather than committing it (operator owns the commit, matching the rest of `/update`).
- Defers to the operator (exit 1) rather than `-f`-forcing past an unexpected staged state, so it can never discard a staged change.

## Consequences

- Adopters upgrading past v5.4.0 get the untrack automatically via `/update`; the inert `.gitignore` entry finally applies and a `git checkout` can no longer overwrite their private config.
- Sets the precedent that a release which changes a config-tracking invariant ships a **real** migration, not a placeholder — the judgement `/release` step 3's soft check exists to prompt.
- `.claude/migrations/` remains framework release tooling, distinct from the DB-migration gate (`require-migration-ticket.sh`), whose paths deliberately do not match this directory.

## Artifacts

- `.claude/migrations/v5.3.0-to-v5.4.0.sh`, `.claude/hooks/tests/test_v54_migration.sh`, `docs/upgrading.md` (this PR, #1131)
- Root cause + framework-side fix: #1065 (`fix(#1031)`)
- Migration-chain design: AgDR-0032; release-time migration check: #1105

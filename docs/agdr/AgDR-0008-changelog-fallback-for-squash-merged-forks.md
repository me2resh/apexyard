---
id: AgDR-0008
timestamp: 2026-04-25T05:00:00Z
agent: claude
model: claude-opus-4-7
trigger: user-prompt
status: executed
---

# CHANGELOG-fallback in check-upstream-drift.sh for squash-merged sync PRs

> In the context of fork maintainers using GitHub's default squash-merge for `/update` sync PRs, facing the problem that the v1.1.0 tag-reachability check (`git tag --merged main`) returns nothing because squash collapses the upstream-tag commit into a synthetic SHA, I decided to add a CHANGELOG-content fallback (`grep ^## \[X.Y.Z\] CHANGELOG.md`) that fires when the tag check fails, to achieve correct silence on caught-up squash-merged forks without breaking the existing merge-commit / rebase paths, accepting that the fallback depends on apexyard maintaining its CHANGELOG with a stable heading format.

## Context

- Tag-based drift detection landed in v1.1.0 (AgDR-0005). It uses `git tag --list --merged "${DEFAULT_BRANCH}"` to ask "has the fork's main absorbed this tag?". The proxy: tag SHA is reachable from the fork's main → tag is "merged" → silent banner.
- Squash-merge breaks this proxy. `git merge --squash` (the default for many GitHub repos via the "Squash and merge" button) collapses N upstream commits into one synthetic squash commit. The squash commit has no ancestor link to the upstream tag's target SHA. The tag stays unreachable from the fork's main → the hook says "vX.Y.Z available" forever, even though the fork is caught up content-wise.
- Discovered on `me2resh/ops#10` (2026-04-23), the first real-world use of the v1.1.0 `/update` skill: ops fork merged via GitHub's default squash-merge, banner kept firing. Filed as `me2resh/apexyard#106`.
- Squash-merge is GitHub's default on many repos. A drift hook that only works for non-default merge modes is a footgun.

## Options Considered

| Option | Pros | Cons |
| -------- | ------ | ------ |
| **A. Fork-tag convention** — after sync PR, manually tag fork main with upstream version | Trivial hook change, zero new deps | Manual step; easy to forget; same failure mode if forgotten |
| **B. CHANGELOG-only check** — replace tag-reachability with CHANGELOG grep | Single source of truth | Loses the working merge-commit/rebase paths' clarity; pure CHANGELOG grep is brittle to format changes |
| **C. Hybrid (tag primary + CHANGELOG fallback) — CHOSEN** | Preserves working paths intact; adds recovery path for squash-merge; no manual step; backward compat | CHANGELOG format dependency; if someone customises CHANGELOG headings, fallback breaks |
| **D. Last-sync state file** — `/update` writes upstream SHA to a committed file at sync time | Most accurate; works for any merge mode | New file convention; requires the file to be committed (not gitignored); migration cost |

## Decision

Chosen: **Option C — Hybrid**. The tag-reachability primary keeps the v1.1.0 fast-path intact for forks that don't squash-merge (small content overhead, exactly the same behaviour). The CHANGELOG fallback fires only when the primary fails and saves the squash-merge case from the misfire. The CHANGELOG format dependency is acceptable because:

1. apexyard owns the CHANGELOG; the format is stable (one team's discretion to evolve, with backward-compat heading patterns).
2. The grep is intentionally tolerant — `^##\s+\[VERSION\]` matches heading variations, and the leading-`v` stripping handles the tag-vs-heading-prefix difference.
3. The fallback is best-effort silence, not a hard claim. If a fork radically customises CHANGELOG and the fallback misses, the user sees an incorrect banner; running `/update` again proves there's no actual delta and the noise is one banner per session — annoying but not blocking.

Option D was rejected for this round because it requires a new file convention (committed, not gitignored) and a migration story for existing forks. If C's CHANGELOG format dependency turns out to bite, revisit D as a follow-up.

## Consequences

**Kept:**

- Tag-reachability primary check — unchanged. Forks using merge-commit or rebase workflows see exactly the same behaviour.
- The `/update` skill — no skill change required. Existing flow works; the hook just tolerates squash-merge afterwards.
- Tag-based drift's "actionable signal" promise — small upstream commits still don't fire.

**Added:**

- `changelog_has_version()` helper in the hook. Tolerant grep against `${DEFAULT_BRANCH}:CHANGELOG.md`.
- Fallback fires in two paths: (1) `LOCAL_TAG` empty (first sync, squash-merged); (2) `UPSTREAM_TAG > LOCAL_TAG` by semver (intermediate sync, squash-merged).

**Non-consequences (explicitly):**

- No CHANGELOG schema enforcement. The hook is tolerant; the maintainer's discretion governs format.
- No new committed state file. The fallback uses an existing artefact (`CHANGELOG.md`) that maintainers already keep current via `/release`.
- No retroactive fix for forks already showing the misfire — they'll go silent the next time their fork's CHANGELOG has the upstream version's heading.

## Artifacts

- Implementing ticket: `me2resh/apexyard#106`
- Hook diff: `.claude/hooks/check-upstream-drift.sh` (added `changelog_has_version` helper + two fallback gates)
- Reference for CHANGELOG format: `CHANGELOG.md` on `me2resh/apexyard` `main` (v1.1.0 onward)
- Prior decision this extends: AgDR-0005 (tag-based drift)

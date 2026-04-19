---
id: AgDR-0005
timestamp: 2026-04-19T18:30:00Z
agent: atlas
model: claude-opus-4-7
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#102
---

# Tag-based upstream drift detection (shift from per-commit)

> In the context of the SessionStart drift banner nagging every forked ops repo on every upstream main commit, facing the choice between keeping commit-based drift, switching to tag-based drift with a fallback, or adding a config flag with both modes selectable per fork, I decided to **switch the default to tag-based drift with a commit-count fallback** (no config flag), accepting that a fork owner who wants bleeding-edge tracking has to ignore the silent banner and run `/update` on their own cadence.

## Context

The upstream drift banner runs on every Claude Code session start. Its job is to tell a fork owner when the upstream apexyard has moved and they should run `/update`. Until v1.1.0 the signal was `git rev-list --count main..upstream/main` — any commit on upstream main that the fork hasn't absorbed. This worked correctly but produced way too much noise for a framework repo with many forks:

- A README typo fix on upstream main fires the banner on every fork.
- A CI tweak fires the banner on every fork.
- A docs-only PR fires the banner on every fork.
- Anything on upstream main that isn't a release fires the banner on every fork.

The failure mode is not wrong output — the banner accurately reports drift. The failure mode is that fork owners *learn to ignore the banner* because most of the time it's shouting about something they genuinely don't need to sync. By the time a real release (`v1.1.0`, `v2.0.0`) ships, the banner has no attention left.

For a framework we expect to have hundreds of downstream forks, getting this right once means every fork owner going forward gets a quiet, actionable banner. Getting it wrong means training every adopter to tune us out.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **(A) Keep commit-based drift** | No code change. Fires even on "important" untagged commits. | Noisy. Trains fork owners to ignore the banner. Scales poorly with upstream activity. |
| **(B) Tag-based drift with commit-count fallback** *(chosen)* | Actionable signal (fires only on new releases). Quiet for chore commits. Brand-new projects with no tag history still get a useful signal via fallback. Zero config. | Relies on upstream tagging discipline. If upstream pushes a critical fix to main and forgets to tag, downstream forks don't see a banner until the next tag. |
| **(C) Config flag (`upstream_sync_mode: tag \| main`)** | Satisfies both audiences — conservative (tag) and bleeding-edge (main). | Doubled surface area. More to document, test, and maintain. Most fork owners won't ever change the default, so the flag is dead weight for the majority. Slippery slope toward more flags. |

### Decision dimensions weighted

| Dimension | Weight | (A) Commit | (B) Tag + fallback | (C) Config flag |
|-----------|--------|------------|--------------------|-----------------|
| **Signal-to-noise in steady state** | Critical | ❌ | ✅ | ✅ (if set right) |
| **Zero-config for fork owner** | High | ✅ | ✅ | ❌ |
| **Works for pre-release projects** | High | ✅ | ✅ (via fallback) | ✅ |
| **Fork owner can still run `/update` ad-hoc** | High | ✅ | ✅ | ✅ |
| **Code surface + maintenance cost** | Medium | ✅ (none) | ~ (small) | ❌ (significant) |
| **Catches critical un-tagged hotfix** | Low | ✅ | ❌ | ✅ (if set to main) |

Options (B) and (C) both dominate (A) on the critical dimension. The choice between B and C turns on whether the config-flag's extra complexity is worth preserving the "catch un-tagged hotfix" case. Judgement call: it isn't. Upstream should **tag hotfixes** — that's what tagging discipline is for. If upstream forgets to tag a critical fix, that's a process failure we should solve at the upstream end, not paper over with a user-facing flag.

## Decision

Chosen: **(B) Tag-based drift with commit-count fallback, no config flag**, because (a) it eliminates the noise problem for steady-state releases without adding config surface, (b) the fallback path handles the "no tags yet" edge case cleanly, and (c) any future need for a bleeding-edge mode can be added later as a pure additive change — we're not locked in.

Implementation specifics in PR #103:

- Hook compares latest upstream tag against the fork's latest merged tag. Fires only when upstream is strictly newer (semver-sorted via `sort -V`). Silent on equal-tag, silent when fork is ahead of upstream tags (e.g. private fork-specific tags).
- `/update` skill distinguishes "new release available" (actionable — defaults to sync) from "unreleased main commits, no new release" (informational — defaults to skip).
- Fallback triggers only when `git tag --merged upstream/main` returns nothing.

## Consequences

Positive:

- Every fork owner going forward sees an actionable banner only when a real release ships. No training-to-ignore.
- The "on v1.0.0 but upstream has 3 docs commits" scenario — which fires the banner every session under commit-based — is now silent.
- One place to bump the signal: `git tag vX.Y.Z` on upstream is both the public release and the downstream nudge. Aligned.

Negative / accepted:

- **Upstream must tag every meaningful change.** A critical hotfix pushed without a tag won't nag downstream. This is accepted because the alternative (firing on every commit) scales worse in aggregate. Upstream process: every merge that users should pull in should land as part of a tagged release.
- **Fork owners who legitimately want bleeding-edge tracking** have to manually run `/update` or watch GitHub releases. For the current user base (ops repos that want stability), this is the right default. If a meaningful cohort wants bleeding-edge, adding the flag later is backward-compatible (default stays `tag`).
- **First session after v1.1.0 ships** will fire the banner on every existing fork naming v1.1.0. That's the intended behaviour — it's the first legitimate release-drift signal under the new regime.

## Artifacts

- PR: https://github.com/me2resh/apexyard/pull/103
- Hook: `.claude/hooks/check-upstream-drift.sh`
- Skill: `.claude/skills/update/SKILL.md` § Preview
- CHANGELOG: `[1.1.0] — 2026-04-19 — Tag-based upstream drift detection`

---
id: AgDR-0007
timestamp: 2026-04-25T03:50:00Z
agent: claude
model: claude-opus-4-7
trigger: user-prompt
status: executed
---

# Adopt release-cut branch model (dev + main + tags) for apexyard

> In the context of external adopters now forking apexyard and pulling from `upstream/main`,
> facing the problem that daily work-in-progress was polluting what downstream users see as "the framework",
> I decided to move daily work to a `dev` branch and reserve `main` for tagged releases (dev → main merge + semver tag),
> to achieve a predictable, adopter-safe upstream without the ceremony of full git flow,
> accepting that contributors need to learn a slightly different target branch and that release cadence must be curated.

## Context

- apexyard started as a single-user framework; `main` was both the working branch and the consumed surface.
- External adopters now fork the repo and sync via `/update` (which pulls `upstream/main`). Every commit on main reaches them immediately.
- Drift detection is already tag-based (apexyard v1.1.0 introduced tag-aware drift). The infrastructure for release semantics exists; the policy did not.
- The model must stay lightweight — apexyard is docs + hooks + skills, not a compiled artefact needing stabilisation windows.
- Eight enforcement-hook PRs (#109/#110/#115/#111/#107/#112/#113/#114) merged to a *temporary* `dev` branch this cycle, awaiting v1.2.0 cut. The branch already exists; this AgDR formalises the policy that brought it into being.

## Options Considered

| Option | Pros | Cons |
| -------- | ------ | ------ |
| **A. Stay trunk-based (status quo)** | Zero change cost; one branch to reason about | Adopters pull WIP; no release promise; cumulative effect on downstream forks |
| **B. Trunk + tags only (forks pin to tags)** | Minimal policy change | `/update` still pulls `main` HEAD unless rewritten to pull latest tag; adopters who don't pin still see WIP |
| **C. Release-cut (dev + main + tags) — CHOSEN** | Clean promise: main = released; light ceremony; compatible with existing tag-based drift | Contributors retarget PRs; release cadence must be curated; slight onboarding friction |
| **D. Full git flow (main + develop + release/* + hotfix/* + support/*)** | Handles multi-version maintenance, stabilisation windows, emergency patches | Heavy for a framework with one supported version and no compilation; most modern teams don't need it; overkill |

## Decision

Chosen: **Option C (release-cut)**, because it gives external adopters the release promise they need without the ceremony they don't. Full git flow's extra branch types (`release/*`, `hotfix/*`, `support/*`) solve problems apexyard doesn't have — there's no stabilisation window, no multi-version maintenance, and no compilation step that benefits from a soak period.

Naming: this is **NOT** git flow. It's "release-cut" or "gitflow-lite". Be precise in docs so contributors who think git flow don't expect the full ceremony.

## Consequences

**Kept:**

- All existing hooks (block-main-push, validate-branch-name, validate-pr-create, merge-gate hooks) — they apply to `dev` PRs as-is.
- Tag-based drift detection — continues unchanged.
- `/update` skill — no behavioural change; semantic upgrade (pulls release-only content).

**Added:**

- `dev` branch as the daily-work trunk; default branch for PRs.
- Release-PR flow (`dev` → `main` + semver tag).
- `/release` skill to standardise the cut (this PR).
- Branch protection on `main` restricting merges to release-PRs only (manual GitHub setting, documented in `docs/release-process.md`).
- `block-main-push.sh` extended to block direct pushes/commits to `dev` too (long-lived integration branch, all changes via PR).

**Dropped:**

- Rolling-HEAD semantics on `main`. Adopters can no longer casually pull unreviewed WIP.

**Non-consequences (explicitly):**

- Managed projects under apexyard governance do **NOT** adopt this pattern. They stay trunk-based because they have no downstream consumers (only the framework does). The `docs/multi-project.md` and CLAUDE.md explicitly call this out so the pattern doesn't cargo-cult into project templates.
- No hotfix/support branches. If multi-version maintenance becomes a need, revisit.
- No automatic on-merge issue closing for dev PRs (GitHub auto-close only fires on default-branch merges). Each dev-PR closes its ticket manually with a merge-trace comment; the eventual release PR's body aggregates all `Closes #N` for the batch and triggers auto-close en masse when it merges to `main`. Workflow automation for the meantime is a follow-up.

## Artifacts

- Implementing ticket: `me2resh/apexyard#116`
- `/release` skill: `.claude/skills/release/SKILL.md`
- Process doc: `docs/release-process.md`
- Hook update: `.claude/hooks/block-main-push.sh` (now also blocks `dev`)
- CLAUDE.md + `docs/multi-project.md` updated to clarify framework-only scope

# Managed-project release versioning

This is the release-versioning convention for **managed projects** under apexyard governance — the repos registered in `apexyard.projects.yaml` (SharpPick and future apps). It is deliberately *different* from how the apexyard framework itself versions, and the difference is the whole point of this doc.

**Read this first if you're about to cut a version on a managed project.** The framework's `dev`/`main` release-cut model is seductive to copy — it's the model you see every day inside this repo — but it solves a problem managed projects don't have. Copying it in is the mistake this doc exists to prevent.

## TL;DR

- **Trunk-based on the default branch.** PRs merge straight to trunk. No `dev`/`main` split.
- **A root `VERSION` file** holds the current semver as plain text — the human-readable single source of truth.
- **One semver git tag per release**, cut directly from the trunk (`vX.Y.Z`).
- **A Keep-a-Changelog `CHANGELOG.md`**, newest-first, with conventional-commit bullets + PR refs.
- **A GitHub Release per tag**, body drawn from that release's changelog section.
- **App Store apps additionally carry `CFBundleShortVersionString` / `CFBundleVersion`** — a separate distribution surface, tracked but not the source of truth.

## Why managed projects are NOT release-cut (the framework contrast)

The framework repo (`me2resh/apexyard`) uses a **release-cut** branch model — daily PRs land on `dev`, and `main` receives only tagged release PRs from `dev`. That model exists for exactly one reason: **the framework has downstream adopters.** External forks pull `upstream/main` via `/update`, so every commit on `main` reaches them immediately. `dev` is the buffer that keeps unreviewed work-in-progress out of what adopters consume; `main` is a curated release promise. See [`docs/agdr/AgDR-0007-release-cut-branch-model.md`](agdr/AgDR-0007-release-cut-branch-model.md) and [`docs/release-process.md`](release-process.md).

A managed project has **no downstream consumers**. Nobody forks a managed app and pulls its `main` as a dependency. There is no adopter to protect from WIP, so the `dev` buffer buys nothing and costs a branch, a retarget habit, and release ceremony. This is why the framework's own guardrails call it out explicitly — from AgDR-0007's non-consequences: *"Managed projects under apexyard governance do NOT adopt this pattern. They stay trunk-based because they have no downstream consumers (only the framework does)."* — and from [`.claude/rules/git-conventions.md`](../.claude/rules/git-conventions.md) § "Branch model — framework only": *"Managed projects … stay trunk-based — PRs merge to `main` directly … Do NOT cargo-cult the dev/main split into project templates."*

| | Framework (`me2resh/apexyard`) | Managed project (SharpPick, other managed apps) |
|---|---|---|
| Branch model | Release-cut: `dev` → `main` + tags | **Trunk-based**: PRs merge to trunk directly |
| Reason | Has downstream adopters pulling `upstream/main` | No downstream consumers |
| Tagged from | `main` only (release PRs) | The trunk, directly |
| Version source of truth | Git tags (drift detection is tag-based) | **Root `VERSION` file** + git tags |
| Release skill | `/release` (refuses to run on a managed project) | Manual cut (this doc) |
| WIP visibility | Hidden from adopters until a release cut | Fine — nobody's consuming trunk |

The two models are not "one is stricter." They're fitted to different consumer topologies. Trunk-based is the *right* model for a leaf project, not a relaxed version of the framework's.

## The trunk

Managed projects are trunk-based: every `feature` / `fix` / `chore` PR merges straight to the repo's default branch, and releases are tagged directly from it. There is no long-lived integration branch.

> **Trunk branch name.** The trunk is whatever the repo's default branch is. New projects should default to `main`. Some existing projects predate that convention and are trunk-based on `master` instead. Either is fine; what matters is that there is *one* long-lived branch and releases tag off it. Don't rename an established trunk just to match a name.

```
main ──●──●──●──●──────●──●──●──────●──●──  (all PRs land here; tagged in place)
       │           │              │
     v1.2.0      v1.3.0         v1.4.0
```

Compare the framework's two-lane diagram in [`docs/release-process.md`](release-process.md) § "Branch model" — the managed-project shape is deliberately one lane.

## The `VERSION` file

A plain text file named `VERSION` at the repo root holds the **current released semver** and nothing else:

```
X.Y.Z
```

Conventions:

- **Bare semver, no `v` prefix.** The file says `X.Y.Z` (e.g. `1.4.0`); the corresponding git tag is `vX.Y.Z` (e.g. `v1.4.0`). The `v` lives on the tag, not in the file.
- **Human-readable single source of truth.** A reader (or a build script, or a launcher's About box) can `cat VERSION` without parsing git. It's the answer to "what version is this?" that doesn't require the git history.
- **Bumped in the release commit**, alongside the CHANGELOG entry — the same commit that gets tagged. `VERSION`, the changelog section, and the tag all move together, so they can never disagree.
- **`VERSION` and the tag are redundant on purpose.** The tag is the machine-consumable anchor (GitHub Releases, `git describe`, CI); the file is the human/tool-readable mirror that survives a shallow clone or a zip export with no git metadata. If they ever drift, the tag on trunk is authoritative and `VERSION` is the bug to fix.

## The changelog

`CHANGELOG.md` at the repo root, in [Keep a Changelog](https://keepachangelog.com) newest-first order. Each release is a section headed by its version and date, with one bullet per merged change in conventional-commit voice, carrying the PR reference:

```markdown
# Changelog

## v1.4.0 - 2026-06-28

- feat(#43): redesign PR4 — themes, a11y, polish (#48)
- feat(#43): redesign PR3b — AI-assist + Stop/Re-run (#47)
- feat: per-item persistent logs (#45)

## v1.3.0 - 2026-06-10

- ...
```

- **Newest section on top** — a reader sees the latest release first.
- **Conventional-commit bullets** (`feat`, `fix`, `refactor`, …) so the changelog doubles as the semver-bump justification: any `feat` → at least a minor bump; a breaking change (`!`) → a major.
- **PR ref in each bullet** (`(#48)`) so every line is traceable back to its review.

## Cutting a release — the flow

Semver bump follows conventional commits since the last tag (breaking → major, any `feat` → minor, only `fix`/`chore` → patch).

```
1. Confirm trunk is green and holds a meaningful batch since the last tag.

2. Pick the version (semver bump from the conventional commits since last tag).

3. In one commit on a short-lived release branch (or directly via a release PR):
   - bump VERSION            (e.g. 1.3.0 → 1.4.0)
   - prepend the new CHANGELOG.md section (version + date + PR-ref bullets)

4. Open the release PR to trunk, run the normal review + CEO merge gate, merge.

5. Tag the merge commit on trunk:
   git tag v1.4.0 <merge-sha>
   git push origin --tags        # --tags, not the bare name (avoids the branch-name validator misfiring)

6. Create the GitHub Release for the tag, body = that release's CHANGELOG section.
```

There is no `dev → main` promotion step and no `/release` skill — `/release` is framework-only and refuses to run on a managed project. The cut is a normal PR plus a tag.

> A reusable auto-tag-on-merge workflow (`golden-paths/pipelines/auto-tag-on-release-pr-merge.yml`) is available if a project wants CI to place the tag instead of a human — optional, not required.

## App Store apps: `CFBundleShortVersionString` / `CFBundleVersion`

macOS / iOS apps distributed through the App Store (e.g. **SharpPick**) carry two Apple-mandated version fields in their `Info.plist`, and these are a **separate distribution surface** from the git/`VERSION`/tag convention above:

| Field | Meaning | Relationship to `VERSION` |
|-------|---------|---------------------------|
| `CFBundleShortVersionString` | The user-facing marketing version (e.g. `1.4.0`) | Mirrors `VERSION` — keep them equal at release time |
| `CFBundleVersion` | The build number — must **strictly increase** for every binary uploaded to App Store Connect, even for the same marketing version | Independent counter; App Store Connect rejects a re-used build number |

Why they're tracked separately:

- **Apple owns the rules.** App Store Connect rejects an upload whose `CFBundleVersion` isn't higher than the last one it saw — regardless of what git or `VERSION` says. A single marketing version (`1.4.0`) may burn several build numbers across TestFlight iterations and resubmissions.
- **`VERSION` stays the source of truth for the *release*; `CFBundleVersion` is the source of truth for the *binary*.** A rejected build that never ships still consumed a `CFBundleVersion`, but it does not consume a `VERSION` bump or a git tag.
- **Practically:** at release time set `CFBundleShortVersionString` = `VERSION`, and let `CFBundleVersion` be a monotonically increasing integer (a build counter or CI run number) that you never reset.

Non-App-Store managed projects (CLIs, web apps, desktop launchers) have no bundle version — for them `VERSION` + tag + changelog is the complete story.

## Should this become a Rex-enforced handbook rule?

Not yet. This convention is young and currently rides on two managed projects. Codify it into a blocking `handbooks/` entry (e.g. "release commit must bump `VERSION` and prepend a CHANGELOG section") only once it's proven across more projects and the failure mode is real and recurring. Until then this doc is the reference and self-discipline is the mechanism — the same posture the framework takes for its own release process before automating it.

## Related

- [`docs/agdr/AgDR-0007-release-cut-branch-model.md`](agdr/AgDR-0007-release-cut-branch-model.md) — the framework's release-cut decision, and its explicit "managed projects do NOT adopt this" non-consequence
- [`docs/release-process.md`](release-process.md) — the framework's own (contrasting) release runbook
- [`.claude/rules/git-conventions.md`](../.claude/rules/git-conventions.md) § "Branch model — framework only" — the trunk-based-for-managed-projects rule
- [`docs/multi-project.md`](multi-project.md) — the portfolio model and the registry these projects live in
- [Keep a Changelog](https://keepachangelog.com) · [Semantic Versioning](https://semver.org) — the external conventions this doc adopts

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

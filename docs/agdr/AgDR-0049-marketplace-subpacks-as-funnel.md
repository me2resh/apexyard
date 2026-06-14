# Marketplace sub-packs (audit-pack + safety-hooks) as a framework funnel

> In the context of ApexYard's framework being a fork-based ops repo (not a drop-in plugin), facing the strategic gap that Claude Code's marketplace surface can't host the integrated whole, I decided to ship two narrowly-scoped sub-packs (`apexyard/audit-pack` and `apexyard/safety-hooks`) as Claude Code marketplace plugins extracted (not forked) from upstream HEAD at release-tag time, to achieve a one-way funnel from plugin users to full-framework adopters without diluting the integrated value, accepting the maintenance overhead of an extraction script + a release-tag CI workflow + a smoke test that asserts no framework-distinctive elements leak into the extracted output.

## Context

ApexYard's value composition — roles + workflows + templates + hooks + skills + rules + handbooks + portfolio + memory + audits — is delivered by **forking** the upstream framework into an ops repo and treating that fork as the governance surface for a portfolio of managed projects. The integrated whole depends on the portfolio registry (`apexyard.projects.yaml`), the role definitions in `roles/`, the bootstrap-skill exemption, the two-marker merge gate, the `_lib-portfolio-paths.sh` resolver, and the per-project `projects/<name>/` doc convention. None of that fits a drop-in plugin shape.

Claude Code ships a marketplace for plugins — additive `.claude/` drop-ins that a project can install without forking anything. (ApexYard's canonical source of truth is now tool-neutral `.apexyard/`; `.claude/` is the generated Claude Code registration layer.) Users who'd benefit from ApexYard's audit suite (`/launch-check` + 8 deep-dives) or its safety hooks (secrets / main-push / git-add-all / pre-push / commit-refs / PR-title / branch-name validation) are not all CTO-class operators ready to fork a 50+ skill framework; many are individual engineers who want one specific capability dropped into their existing project.

The strategic question is whether to (a) ignore the marketplace surface entirely, (b) publish the entire framework as a single mega-plugin (doesn't fit — the framework IS the ops repo), or (c) extract narrowly-scoped sub-packs that stand alone as plugins AND pitch the full framework as a graduation path. Option (c) — sub-packs as a funnel — is the discovery vector for individual engineers to encounter ApexYard, run one sub-pack, and self-select into the full framework when their scope grows.

Two scope-and-maintenance shapes were on the table:

- **Forked sub-packs** — separately-maintained codebases for each sub-pack. The marketplace versions diverge from upstream over time as adopter feedback drives sub-pack-specific changes. Two consequences: (i) the framework loses single-source-of-truth, (ii) bug fixes have to be ported across N codebases. Rejected.
- **Extracted sub-packs** — sub-packs are generated from upstream HEAD at release time. The framework remains the single source of truth; the sub-packs are a packaging artefact, not a code-fork. Chosen.

The performance constraint from the ticket (and operator memory) makes the extraction discipline mechanical: the sub-packs MUST NOT include framework-distinctive elements (portfolio registry, `/handover`, role definitions, `_lib-portfolio-paths.sh` dependencies), AND the same files serve both distribution channels — sub-pack extraction is a packaging concern, not a code-fork. A smoke test asserts both invariants on every CI run.

## Options Considered

### Scope — which sub-packs to ship in v1

| Option | Pros | Cons |
|--------|------|------|
| Single mega-plugin (full framework) | One marketplace entry; "everything" discoverable in one shot | Doesn't fit the marketplace shape (framework IS the ops repo, not a drop-in); plugin install would either be missing the portfolio surface or pretend to ship it; user confusion guaranteed |
| **Two sub-packs in v1 (chosen)**: `audit-pack` + `safety-hooks` | Both genuinely self-contained — neither leans on the portfolio model, `/handover`, or role definitions; each represents a coherent capability cluster; the funnel pitch sits on each README; ships in one PR | Two marketplace entries to maintain; two READMEs to keep in sync; the "full apexyard plugin" question keeps coming up until the funnel READMEs explain why it doesn't fit |
| Four sub-packs in v1 (add `/rex` + `/migrations`) | Broader marketplace surface | `/rex` depends on the session-state convention (`.apexyard/session/reviews/<pr>-{rex,ceo}.approved`) and the strict per-PR CEO approval pattern — both hard to ship as a drop-in; `/migrations` depends on migration ticket label + AgDR + tracker-aware hooks — too entangled with the integrated whole for v1 |
| One sub-pack in v1 (`audit-pack` only) | Smallest blast radius; lowest extraction-script complexity | `safety-hooks` is genuinely self-contained AND high-value (every project benefits from secrets-scan + main-push-block); shipping only one sub-pack postpones the funnel without buying a stable v1 |

### Maintenance contract — how the sub-packs track upstream

| Option | Pros | Cons |
|--------|------|------|
| **Generated, not forked (chosen)** — sub-packs extracted from upstream HEAD at release time | Framework remains single source of truth; bug fixes flow automatically to sub-packs on next release; one codebase to lint and test | Requires an extraction script + release-tag CI workflow; smoke test must catch leakage of framework-distinctive elements |
| Forked sub-packs — separately maintained repos | Sub-pack-specific UX changes possible without churning the framework | Loses single-source-of-truth; bug-fix port matrix; release coordination across N repos; defeats the funnel narrative (a forked sub-pack that drifts from upstream isn't a teaser for upstream) |
| Symlink-based — sub-packs are symlinks into the upstream tree | Trivial; zero packaging step | Symlinks don't survive packaging into a marketplace plugin tarball; the resulting plugin would point at paths the user doesn't have |

### Extraction mechanism — when extraction runs

| Option | Pros | Cons |
|--------|------|------|
| **Release-tag-driven CI workflow + manual `bin/extract-subpacks.sh` (chosen)** | Re-bundles automatically on every framework release tag; the script is also invokable manually for local validation / debugging; one source of truth for the extraction logic | One workflow file to maintain; the script has to graceful-degrade when jq / find aren't available (used both in CI and locally) |
| Every-PR-driven CI | Sub-packs always reflect the very latest commit | Excessive — most PRs don't change anything sub-pack-relevant; the marketplace doesn't want a release per PR anyway |
| Manual-only — operator runs `bin/extract-subpacks.sh` before each marketplace push | Zero CI overhead | Easy to forget; the marketplace ships drift |

### Publishing path — release-tag-driven vs every-PR-driven

| Option | Pros | Cons |
|--------|------|------|
| **Release-tag-driven (chosen)** — extraction runs on every framework release tag; publish to marketplace is a manual operator step gated on the AgDR | Each marketplace release maps to a framework release; semver alignment; operator owns the push moment | One extra step between extraction and marketplace push; v1 doesn't auto-publish |
| Every-PR-driven auto-publish | Continuous delivery | Marketplace churn; semver becomes meaningless; every WIP commit lands on real users |
| Manual extraction + manual publish | Maximum operator control | Easy to forget extraction; sub-packs drift from upstream |

### Layout — where the sub-packs live in the upstream repo

| Option | Pros | Cons |
|--------|------|------|
| **`marketplace/<pack>/` at repo root (chosen)** | Self-documenting on disk; mirrors the marketplace plugin shape (an `.apexyard/` subdir + a README + a manifest); easy to gitignore from the framework's own discovery (Wave 1 invariant test ignores nested `.apexyard/skills/`) | One more top-level dir |
| `.apexyard/marketplace/<pack>/` nested under the framework's own `.apexyard/` | Keeps marketplace concerns under `.apexyard/` | Risks tool-agnostic skill-discovery globber picking up the nested `.apexyard/skills/` and double-counting; Wave 1 invariant would need an explicit exclusion |
| `dist/marketplace/<pack>/` as a build artefact only | Clean separation of source from artefact | Hides the extracted output from grep / git review; CI would need to commit the build output anyway, defeating the build-artefact framing |

## Decision

Chosen — **the two-sub-pack scope (`audit-pack` + `safety-hooks`), the generated-not-forked maintenance contract, the release-tag-driven CI extraction workflow paired with a manual `bin/extract-subpacks.sh` script, and the `marketplace/<pack>/` layout at repo root**, because:

1. **Strategic shape.** Two sub-packs is the smallest credible v1 — one alone doesn't establish a marketplace presence, three+ stretches into capabilities that aren't cleanly drop-in-able yet.
2. **Maintenance discipline.** Generated-not-forked keeps the framework as single source of truth. The funnel direction (plugin → framework) only works if the marketplace version is a faithful subset of upstream; a forked sub-pack that drifts is a different product.
3. **Extraction is a packaging concern.** The sub-packs reuse the same skill / hook / lib files that serve the integrated framework. No code-fork, no behavioural divergence. The extraction script is a copy + manifest + sanity-check, not a transform.
4. **Performance contract — path-leak guard + acknowledged prose hints.** A smoke test asserts no framework-distinctive *paths* (`apexyard.projects.yaml`, `_lib-portfolio-paths.sh`, `/handover` skill dir, `portfolio_*` libs) appear in the extracted file tree, AND that the same files serve the integrated framework without modification. **Important honesty caveat**: the path-leak guard is a path-scan, not a content-scan. Extracted skill / hook / lib files DO retain prose references to upstream framework primitives — e.g. SKILL.md author guidance that says "read `<name>` from `apexyard.projects.yaml`", or `_lib-audit-history.sh` calling `portfolio_projects_dir()` inside a `command -v` fallback. These are **deliberate** pointers to the full framework consistent with the funnel direction (sub-pack → full framework), NOT bugs. The lib calls graceful-degrade to `git rev-parse --show-toplevel/projects` outside an apexyard fork. The audit-pack README's "Known framework references" section enumerates the surface so adopters know what they're seeing. Rationale: scrubbing every prose reference would either lose the funnel pitch (sub-packs become orphans, not graduation paths) OR require a code-fork that contradicts the generated-not-forked contract (decision #3). **v2 may revisit** if marketplace adopters consistently surface the prose hints as friction, but v1 ships honest-scope.
5. **Funnel direction is one-way.** Each sub-pack's README pitches the full framework as the graduation path but does not pressure. The pitch points; it does not push.
6. **`/rex` and `/migrations` deferred.** The two-marker merge gate is tied to the session-state convention (`.apexyard/session/reviews/`); the migration gate is tied to a labelled tracker issue + AgDR pattern. Both work, but neither survives extraction into a drop-in shape without losing the gate's value. Defer until v2 after the first two sub-packs land.

## Consequences

### What ships in this PR

- `marketplace/audit-pack/` — extracted `/launch-check` + 8 deep-dive audit skills + `_lib-audit-history.sh` + `_lib-read-config.sh` + audit templates + AI-crawler registry, plus a funnel-pitching README and a marketplace manifest
- `marketplace/safety-hooks/` — extracted 7 safety hooks + `_lib-tracker.sh` + `_lib-read-config.sh` + `_lib-ops-root.sh` + a `settings.snippet.json` showing recommended hook wiring, plus the same funnel-pitching README and a marketplace manifest
- `bin/extract-subpacks.sh` — the extraction script, idempotent, with a manifest of what was extracted + the upstream commit SHA
- `.apexyard/hooks/tests/test_subpack_extraction.sh` — smoke test asserts no framework-distinctive tokens leak into the extracted output AND that both sub-packs' file inventory matches the AgDR-documented list
- `.github/workflows/extract-subpacks-on-release.yml` — CI workflow that re-runs the extraction on every framework release tag (pushes to a sync branch; the marketplace push remains a manual operator step in v1)

### What does NOT ship in this PR

- Actual `gh marketplace publish` (or equivalent) calls. The scaffolding lands; the publish step is operator-driven once the AgDR is approved.
- Automated marketplace publishing on every framework PR. Release-tag-only in v1.
- `/rex`, `/migrations`, `/c4-arch`, or other sub-packs. Defer until the first two have a publishing flow.
- Translations to Cursor / Aider / Cline marketplaces. Out of v1.

### Ongoing obligations

- **Every framework release tag re-runs the extraction.** Failed extraction = the release tag's CI fails. The release author owns the fix.
- **The smoke test is part of the framework's own test suite.** It runs in the standard test path (alongside Wave 1 invariants and the other `test_*.sh` shellscripts). A PR that legitimately adds a framework-distinctive token to the extracted files will fail the smoke test until either the token moves out of the extracted set OR the test's allowlist is updated.
- **Each sub-pack's README is part of the funnel.** Updates to the framework's pitch propagate through the next extraction. The README content lives in `marketplace/<pack>/README.md` (committed; not generated), so adopter-facing copy is reviewable in the same PR that changes it.

### What v2 will look at

- `/rex` sub-pack — once the session-state convention is decoupled from the merge gate (or a stand-alone gate variant is shipped that doesn't require it)
- `/migrations` sub-pack — once the migration gate has an "operator-only" mode that doesn't depend on the framework's tracker label + AgDR pattern
- `/c4-arch` sub-pack — bundling `/c4` + `/dfd` + `/tech-vision` as an architecture-docs sub-pack
- Automated marketplace publish — once the v1 release-tag flow has run for ~6 months and there's confidence the publish step is safe to automate

## Artifacts

- `marketplace/audit-pack/`, `marketplace/safety-hooks/`
- `bin/extract-subpacks.sh`
- `.github/workflows/extract-subpacks-on-release.yml`
- `.apexyard/hooks/tests/test_subpack_extraction.sh`
- This PR (closes me2resh/apexyard#321)

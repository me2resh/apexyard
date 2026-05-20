# AgDR-0047 — Framework packaging & distribution

> In the context of distributing ApexYard to new adopters and shipping updates to existing ones, facing the cost of `git pull upstream` merge conflicts on every framework-file customisation and the absence of version pinning / clean install boundaries, I am **proposing** a packaging strategy decision with six options compared (status quo, release tarball, layered install, npm, Homebrew, one-line install script), leaning toward **layered install** for its conflict-free upgrades + version pinning, accepting that layered install is a breaking change for every existing adopter and that the migration path must be designed before any implementation lands.
>
> **Status: PROPOSED.** Operator (Ahmed) will pick via a PR comment on the AgDR PR. The Decision section will be rewritten from PROPOSED → ACCEPTED + chosen option once the pick is in.

**Metadata** — Status: PROPOSED · Category: architecture · Supersedes: none · Related: [AgDR-0007](AgDR-0007-release-cut-branch-model.md), [AgDR-0021](AgDR-0021-split-portfolio-v2-path-resolution.md), [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md). (Body-H1 only, no YAML frontmatter — the framework's live convention since markdownlint MD025 trips on YAML `title:` + body H1 simultaneously; documented for future-us in case the templates/agdr.md shape suggests otherwise.)

## Context

ApexYard distributes today via the **fork-as-install** model:

- Adopter forks `me2resh/apexyard` on GitHub
- Clones the fork locally, sets `upstream` remote pointing back at the canonical repo
- Runs `/setup` to fill in `onboarding.yaml`, registers projects in `apexyard.projects.yaml`
- Pulls updates with `/update`, which runs `git fetch upstream && git merge upstream/main` on a sync branch (release-cut model — see [AgDR-0007](AgDR-0007-release-cut-branch-model.md))

This works and has shipped the framework to several adopters. The pain points that motivate this AgDR:

1. **Conflict surface grows with customisation.** Framework files (`.claude/settings.json`, role files in `roles/`, skill `SKILL.md`s, hook scripts) live in the adopter's git tree alongside their own customisations. Any local edit to a framework file becomes a permanent merge-conflict candidate on every upstream sync. Adopters who tweak hooks, settings, or skill behaviour pay this tax forever.

2. **No version pinning.** There is no mechanical way to declare "this fork is on apexyard@1.3.0". The release-cut model tags releases on `main`, but the adopter is on whatever commit they last merged. Skills that say "requires framework ≥ #242" can only be checked against `git log` — there is no manifest the framework can read at runtime.

3. **No clean install boundary.** Framework-essential paths (`.claude/`, `roles/`, `workflows/`, `templates/`) and adopter-customisation paths (`onboarding.yaml`, `apexyard.projects.yaml`, `projects/<name>/`, `custom-skills/`, `custom-handbooks/`) are not separated at the filesystem level. There is no `apexyard uninstall`, no way to mechanically tell *"what came from the framework vs what I wrote"*.

4. **No try-before-fork path.** Today's first-touch is *"fork on GitHub and commit to it"*. There is no `npx apexyard init` or `brew install apexyard` shape for adopters who want to evaluate the framework against an existing project without committing to a fork first.

5. **Customisation overlay is partial.** [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md) introduced `custom-templates/` (path-mirroring overrides for templates). Framework PR #243 introduced `custom-skills/` and `custom-handbooks/`. These solve part of the conflict problem for one slice each, but adopter overrides on `.claude/settings.json`, individual hooks, agents, role files, or skill `SKILL.md`s still require editing the framework's checked-in file. The "override layer" exists but is incomplete and inconsistent.

The brand-visibility argument that motivated the fork-as-install model in the first place — pre-v1 ApexYard lived inside a `.apexyard/` dotfile dir which was invisible to `ls` and GitHub views — is real and worth preserving. Any new packaging model must keep ApexYard discoverable on the adopter's GitHub org.

## Options Considered

| # | Option | Pros | Cons | Migration cost |
|---|--------|------|------|----------------|
| 1 | **Fork-as-install** (status quo: clone, `git pull upstream`, `/update` skill) | Already shipping; brand-visible (fork on GitHub); single tool surface (`git`); zero migration; works on every OS | Conflict surface grows forever on every customised file; no version pin; no install boundary; no try-before-fork path; no clean uninstall | None |
| 2 | **Release-tarball delivery** (`gh release download apexyard-v1.3.0.tar.gz`, extract over fork, run installer) | Smallest change with biggest immediate UX win — `/update` becomes a tarball overlay; eliminates merge conflicts on framework files for non-customising adopters; version field is the tag name; brand visibility preserved | Adopters who DID customise framework files silently lose their edits on every `/update`; loss of `git log` for framework files inside the fork; still no install boundary; partial fix only | Low — `/update` skill rewrite + release-attachment workflow on framework side; no adopter migration |
| 3 | **Layered install** (read-only framework dir + adopter customisation overlay, XDG-style: `~/.local/share/apexyard/` + `~/.config/apexyard/`, OR repo-local equivalent) | Conflict-free upgrades forever (framework dir never edited by adopter); version-pinnable (manifest with version + checksums); clean install boundary; supports `apexyard uninstall`; supports try-before-fork (`apexyard init` in any repo); generalises the existing `custom-*` overlay pattern | Breaking change for every existing adopter (requires migration skill); re-introduces a hidden-dir flavour the v1 dotfile model moved away from (mitigable: keep visible registry + visible `README.md` at fork root); requires a new install tool (CLI shim) | **High** — every existing adopter migrates; framework refactor relocates `.claude/`, `roles/`, `workflows/`, `templates/` under the install dir; precedent shape is `/split-portfolio` (#146) |
| 4 | **npm package** (`npx apexyard init` for first-touch, `npm update apexyard` for syncs; lockfile-pinned versions) | Standard install pattern familiar to most adopters; version-pinnable via `package.json` + lockfile; great try-before-fork story (`npx`); composes with JS/TS adopters who already have a `package.json` | Forces Node + npm dependency on every adopter (currently optional — only `/process` lint needs Node, and that graceful-degrades); awkward for adopters whose ops fork is not a Node project (Python shop, Go shop); brand visibility weaker than fork; doesn't solve "where do framework files live in the adopter's repo" — still need a layered or overwriting install strategy underneath | Medium — JS/TS adopters adopt smoothly via `package.json`; non-JS shops bear awkwardness or skip; framework ships an npm-publish CI step on release tag |
| 5 | **Homebrew formula** (`brew install apexyard`, then `apexyard init` in any repo) | Familiar pattern for macOS adopters; version-pinnable via Homebrew tap; clean install/uninstall via `brew uninstall`; nice CLI entry point | macOS / Linux-only (Windows adopters get nothing — and Windows is the framework's known gap from `link-custom-skills.sh` already); requires a separate distribution channel (`brew tap me2resh/apexyard`); doesn't answer *"what about the fork?"* — formula still installs *something somewhere*; brand visibility lower than fork | Medium — `brew tap` setup + per-release formula bump; Windows adopters unsupported (no migration path); needs an additional distribution channel |
| 6 | **One-line install script** (`curl -fsSL https://yard.apexscript.com/install.sh \| sh`) | Trivial first-touch; works cross-platform with a shell; no package-manager dependency; lowest friction for evaluation | `curl \| sh` is widely considered a security anti-pattern many orgs ban outright; hardest to version-pin (the script has to do the pinning, and the user can't easily inspect what version they got); doesn't solve any of the upgrade-conflict issues — it's only a first-install convenience; requires a domain + hosted script; brand visibility low | Low — script is additive; doesn't change the underlying install model (would compose with 1, 2, 3, 4) |

### Combination plays worth flagging

- **2 + 3 staged.** Ship release-tarball delivery (option 2) now as a transition step, then move to layered install (option 3) once the tarball pipeline is established. Lowers the "big-bang migration" risk of option 3 in exchange for shipping two refactors instead of one.
- **3 + 4 layered.** Layered install IS the model; npm package is the *delivery channel* for the layered install (npm pulls the read-only framework dir). Buys both "standard install pattern" and "conflict-free upgrades" at the cost of forcing Node on every adopter.
- **3 + brand mitigation.** Layered install + a generated `README.md` at fork root that names ApexYard, keeps the `apexyard.projects.yaml` registry at fork root (visible), and uses a visible install dir name (`apexyard/`, not `.apexyard/`). Preserves brand visibility while keeping the conflict-free-upgrade benefit.
- **6 + any of 1–5.** A one-line install script is additive — it can wrap any of the underlying models. Cheapest first-touch UX win regardless of which install model is picked.

## Recommendation

**Lean: option 3 (layered install) with the "3 + brand mitigation" pattern.**

Rationale:

1. **The conflict surface is the root cause.** Options 4, 5, 6 are first-install conveniences; they don't fix the recurring upgrade-conflict tax adopters pay forever on every customised framework file. Option 2 fixes upgrades but silently overwrites adopter framework-file edits — same root cause, masked rather than removed.
2. **Version pinning matters for skill compatibility.** As the framework grows (#242 introduced v1 → v2 portfolio path resolution; #243 introduced custom-skills + custom-handbooks; #340 added site-counts drift prevention), skills increasingly declare *"requires framework ≥ N"*. Without a pinnable version, adopters discover compatibility breaks at runtime. A manifest with `framework_version: 1.3.0` makes this declarative.
3. **The brand-visibility concern that motivated the original fork-as-install choice is mitigable.** Use a visible install dir (`apexyard/` not `.apexyard/`), keep the registry at fork root, ship a fork-root `README.md` naming the framework. The brand argument was real in v1 but not load-bearing on the dotfile choice itself.
4. **Migration cost is one-time.** Option 3 is breaking, but every other option that materially fixes the upgrade-conflict issue is also breaking (option 7 — submodules — is worse on adopter UX; option 2 silently mutates). One painful migration is preferable to a permanent tax. The framework has the `/split-portfolio` precedent (#146) for shipping breaking migrations with explicit operator-confirmation gates and a destructive-recovery rehearsal.

The trade explicitly **NOT** recommended: option 1 (status quo / "do nothing"). The pain is real and growing; punting accumulates conflict-resolution effort across every adopter forever, and the customisation overlay pattern is already drifting toward layered install via the partial coverage in `custom-templates/`, `custom-skills/`, `custom-handbooks/`.

The operator may still pick option 2 as a staged first hop (combination 2 + 3 above) to de-risk the migration — that's a legitimate read of the trade-offs.

## Decision

**PROPOSED — awaiting operator pick via PR comment.** This AgDR will be updated to ACCEPTED with the chosen option, plus any combination notes, after the operator comments on the PR.

Operator input requested on:

- Which option (or combination) to pursue
- If layered install (option 3): brand-visibility mitigation shape — visible `apexyard/` dir vs dotfile `.apexyard/` vs XDG default
- If staged (option 2 → option 3): timeline / commit for the second hop, or single-step commit
- Migration story: blocking `/update` until the adopter has migrated, vs. parallel-track support during a transition window
- One-line install script (option 6): ship in parallel with whichever underlying model is picked, or defer

## Consequences

This AgDR is reversible (supersedeable by a later AgDR) but the downstream implementation cost compounds with each shipped feature that depends on the chosen packaging shape. Honest articulation of the risks:

- **Migration path articulation is required before any implementation lands.** If option 3 (or 7 from the combination plays) is picked, every existing adopter must run a migration skill before their next framework update. The framework has the `/split-portfolio` precedent for this — explicit destructive-recovery flow with operator-confirmation gates, idempotent re-runs, and a default-no `dry-run` mode. A similar `/migrate-to-layered` skill would need to ship before the first layered-install release tag.
- **Downstream implementation cost compounds.** Every new skill, hook, or rule from the date this AgDR lands implicitly assumes the chosen packaging model. Picking late means more refactor on every feature shipped between now and the pick.
- **The AgDR is reversible but compounding cost rises.** The longer the framework ships under the status-quo packaging while a different model is the "right" target, the larger the migration. Operator pick should be timely; this AgDR is not a "park and revisit next quarter" artefact.

Sketch of post-decision consequences per option (placeholders to be expanded in the chosen-option follow-up AgDR):

If **option 3 (layered install)** is chosen:

- Every existing adopter runs a migration skill (provisional `/migrate-to-layered`) before their next framework update
- Framework refactor relocates `.claude/`, `roles/`, `workflows/`, `templates/` under a new install dir
- `CLAUDE.md` rewrites its `@.claude/rules/*.md` imports to point at the new install dir
- A new manifest file records framework version + file checksums; `/update` becomes a manifest-driven file-replace
- `/update` no longer touches git for framework files; version drift is reported from manifest mtime + version field
- `custom-templates/`, `custom-skills/`, `custom-handbooks/` overlay patterns generalise: adopter can also overlay `.claude/settings.json`, individual hooks, individual rules — all from outside the install dir
- [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md) and PR #243 become the dominant customisation path, not an exception

If **option 2 (release-tarball)** is chosen instead:

- `/update` skill is rewritten to download + extract; existing fork structure preserved
- Adopters who customised framework files must be warned at `/update` time; opt-in protection (config-driven allow-list) needs separate design
- No version-pin manifest; framework-version drift continues to read from `git log`

If **option 1 (status quo)** is chosen:

- Document the trade-off explicitly in `docs/multi-project.md` so adopters know the upgrade-conflict tax is intentional
- File a follow-on ticket to ship partial mitigations — more `custom-*` overlay paths — instead of fundamental restructure

## Artifacts

- Tracker ticket: [me2resh/apexyard#265](https://github.com/me2resh/apexyard/issues/265)
- Related: [AgDR-0007](AgDR-0007-release-cut-branch-model.md) — release-cut branch model (the version source any pinned packaging would target)
- Related: [AgDR-0021](AgDR-0021-split-portfolio-v2-path-resolution.md) — split-portfolio path resolution (the customisation-overlay pattern this AgDR generalises)
- Related: [AgDR-0023](AgDR-0023-custom-templates-override-semantics.md) — `custom-templates/` override (the path-mirroring shape this AgDR scales up)
- PR: (will be filled in once opened)

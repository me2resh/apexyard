# AgDR-0021 — Split-portfolio v2 path resolution: marker file, migration shape, and consumer routing

> In the context of moving `onboarding.yaml` and `workspace/` into the private sibling repo (#242), facing the choice of how the public fork advertises itself to ops-root walkers once neither of the legacy anchor files is present, plus four sub-decisions about migration shape, I decided **a presence-only marker file (`.apexyard-fork`) with an explanatory comment writers MAY include, default-yes migration default with per-file-class y/n, `mv` over `cp+delete`, v2-marker precedence over legacy-pair anchor, and no symlink fallback for the v2 additions**, to achieve a clean ops-root resolution that works in both v1-legacy and v2-migrated forks without forcing adopters through a synchronous migration, accepting that adopters who manually delete the `.apexyard-fork` marker after a v2 migration will appear to the framework as un-configured forks.

## Context

Split-portfolio mode (introduced in AgDR-0010 / framework #145) moved the registry + per-project docs to a private sibling repo. v2 (#242) extends this to `onboarding.yaml` + `workspace/`, so the public fork holds only framework files + adopter customisations to skills/hooks/rules. That sounds like a small file-shuffle but it forces several load-bearing decisions because today's ops-root walk-up requires BOTH `onboarding.yaml` AND `apexyard.projects.yaml` at the candidate dir to identify the fork — after v2, neither file is in the public fork. We need a new anchor; we need to keep legacy adopters working; we need a migration; we need it to be safe.

## Options Considered

### A. Public-fork anchor: marker file vs sentinel config key vs `.git`-walk + heuristic

| Option | Pros | Cons |
|---|---|---|
| **Marker file `.apexyard-fork` (chosen)** | One-line presence check, language-agnostic, no parsing. Trivial to write at `/setup` or `/update` migration time. Idempotent (`touch`). | Adopters who manually `rm` it after a v2 migration silently break the walk. Mitigated by a clear filename + README mention. |
| Sentinel config key in `.claude/project-config.json` (e.g. `apexyard.fork_anchor: true`) | Co-located with other config. Parseable. | Requires reading/parsing JSON on every walk-up step (~7 hooks call this). A presence-check is ~10× cheaper. Operators who hand-edit the config can accidentally remove the key with no visible feedback. |
| `.git` + heuristic (e.g. `.git` + `.claude/` + `roles/` present) | No new file. | Heuristic. Brittle. Any repo with a similar structure passes the check (e.g. a fork-of-fork that's renaming things). False positives are confusing. |
| New top-level dotfile like `.apexyard` (single file, JSON inside) | Carries metadata (framework version, fork ID). | Overkill for v2's needs. Migration burden — adopters now have to maintain JSON. Reach for it later if metadata grows. |

### B. Marker content semantics: strictly empty vs explanatory comment allowed

| Option | Pros | Cons |
|---|---|---|
| **Presence-only with optional explanatory comment (chosen)** | Writers can include a single-line comment for human-grep ("# This file marks the directory as an ApexYard ops fork (split-portfolio v2)."). Readers ignore content; only presence matters. Hooks stay simple (`[ -f .apexyard-fork ]`). | Spec must explicitly say "readers MUST ignore content" so future maintainers don't add content-parsing logic. |
| Strictly empty (`touch` only, no content) | Zero ambiguity for readers. | Operators grepping the dotfile find nothing useful; first-time encounter is "what does this mean?". |
| Structured content (e.g. JSON with `version: 2`) | Carries version info for future migrations. | Couples the anchor to a schema. Writers must validate; readers must parse. Overkill for v2 (version is implied by file presence — pre-v2 forks don't have the marker). |

### C. Migration default: opt-in vs default-yes vs auto-apply

| Option | Pros | Cons |
|---|---|---|
| **Default-yes with per-file-class y/n (chosen)** | Adopters who want the v2 layout get it without typing. Adopters who want to defer can say `n` to one or both file classes. Idempotent re-run. | Some adopters will accept the default without reading; the migration is destructive (mv). Mitigated by per-file-class confirmation + dry-run flag. |
| Opt-in (default-no, operator types `y` to migrate) | Conservative; nothing changes by default. | Most split-portfolio adopters WANT v2 (it's the privacy upgrade they signed up for); making them opt in adds friction without value. |
| Auto-apply with no prompt | Fastest. | Destructive ops with no consent is a framework anti-pattern. Even `/setup` confirms before writing files. |

### D. Migration mechanics: `mv` vs `cp+delete`

| Option | Pros | Cons |
|---|---|---|
| **`mv` for workspace/, `cp -p` + `git rm --cached` for onboarding.yaml (chosen — refined #317)** | Each file class gets the right semantics for its role. `workspace/` is gigabytes of clones — moving avoids doubling disk for no benefit. `onboarding.yaml` is small (KB) and acts as a legacy ops-root walk-up fallback, so a public-fork snapshot is a safety net rather than dead weight. Untracking via `git rm --cached` ensures the snapshot can't drift into commits. | Per-file-class semantics costs a sentence of doc explanation; the apparent inconsistency is intentional. |
| `mv` for both (initial v2 design — superseded by #317) | Single recipe, atomic on common case. | Loses the legacy ops-root walk-up fallback if the marker is accidentally removed. Forces adopters to re-run `/update` if they need an `onboarding.yaml` snapshot back. Conflates "small config file" with "gigabytes of clones" — same hammer for two very different nails. |
| `cp+rm` for both | Explicit two-step. | Doubles disk for `workspace/` (gigabytes); no compensating benefit. |
| `rsync --remove-source-files` for both | Robust against interruption. | Heavy dependency for what `mv` does natively. Adds a tooling assumption. |

### E. v2-marker vs legacy-anchor precedence in `_lib-ops-root.sh`

| Option | Pros | Cons |
|---|---|---|
| **v2-marker precedence, legacy as fallback (chosen)** | Migrated adopters benefit from the cheap presence-check first. Un-migrated adopters still work via the legacy `onboarding.yaml + apexyard.projects.yaml` walk. Zero behaviour change for single-fork adopters (they have onboarding.yaml + apexyard.projects.yaml at their root regardless). | Two code paths to maintain forever (until we sunset the legacy pair). |
| Legacy first, v2 fallback | Backwards-compatible by default. | Slower for v2-migrated adopters (parse two files instead of one stat). Loses the "v2 is the new default" signal. |
| v2 only (drop legacy walk after a deprecation window) | Single code path. | Forces every legacy adopter through `/update` migration before the next framework release. Aggressive. |

### F. Symlink fallback for v2 additions (onboarding, workspace_dir)

| Option | Pros | Cons |
|---|---|---|
| **No symlink fallback for v2 additions (chosen)** | v2 requires the config block; symlink mode predates v2's plumbing. The config block has been recommended since #145. Adopters on the old symlink mode are framework-versions behind; they should upgrade the symlink-to-config-block first, then opt into v2. | Adopters on symlink-mode have a forced upgrade path. Documented in `docs/multi-project.md`. |
| Allow symlinks for v2 additions (onboarding.yaml + workspace as symlinks into private repo) | Backwards-compatible with symlink-mode adopters. | Doubles the per-file resolution surface. Operating-system-fragile (Windows symlinks differ). Adopters who land on the symlink path will keep using it; the "config-block is the future" signal is muted. |

### G. Workspace README handling: include in migration vs exclude as framework file

| Option | Pros | Cons |
|---|---|---|
| **Exclude `workspace/README.md` (chosen)** | The README is a committed framework artefact explaining the `workspace/*/` convention — it ships in the public fork and stays there. Migrating it would leave a gap in the public fork's convention docs. | Migration recipe gains a special case (`name == "README.md"` → skip). One-line check in both `/update` step 8a AND the manual recipe. |
| Move it with everything else | Simpler recipe (no special case). | Leaves the public fork's `workspace/` empty of any guidance; first-time visitors to a v2 public fork find an empty dir with no explanation. |

## Decision

Chosen — for all seven:

**A.** Marker file `.apexyard-fork` at the public-fork root.
**B.** Presence-only semantics; writers MAY include a one-line explanatory comment; readers MUST ignore content.
**C.** Default-yes migration with per-file-class y/n confirmation + dry-run.
**D.** Per-file-class semantics — `cp -p` + `git rm --cached` for `onboarding.yaml` (sibling becomes canonical, public-fork copy stays as a gitignored snapshot for the legacy ops-root fallback), `mv` for `workspace/` contents (gigabytes of clones — doubling disk has no benefit). Refined in #317; see § H below for the full rationale.
**E.** v2-marker checked first; legacy `onboarding.yaml + apexyard.projects.yaml` pair as fallback for un-migrated forks.
**F.** No symlink fallback for v2 additions; config block required (consistent with the framework-#145+ direction).
**G.** `workspace/README.md` stays in the public fork during migration; both the skill and manual recipe special-case it.

Why this combination:

1. **Marker file + presence-only** maximises simplicity. Adopters reading their public fork's root see `.apexyard-fork` and either recognise it from the docs or one `head` reveals the explanatory line. Walkers do a single `[ -f ]` check. No format ambiguity, no schema to evolve.
2. **Default-yes migration** matches adopter intent. Split-portfolio adopters chose privacy; v2 extends the privacy promise. Defaulting to migrate is the right user-respecting choice; per-file-class y/n + dry-run leave the safety net intact.
3. **v2-precedence with legacy fallback** lets every adopter cohort work simultaneously. Single-fork adopters never touch the v2 path. v1-split-portfolio adopters work until they migrate. v2-migrated adopters benefit from the faster anchor.
4. **No symlink for v2** keeps the surface small. Symlink mode is legacy from before the config block existed; pushing v2 there too would mean two parallel resolution paths forever.
5. **`workspace/README.md` stays public** preserves the framework's documentation of its own convention without leaking adopter content.

## H. v1→v2 migration semantics — per-file-class copy-vs-move (refined #317)

The initial v2 implementation used `mv` for **both** `onboarding.yaml` and `workspace/`. In practice this had two problems:

1. **Loss of the legacy ops-root fallback.** `_lib-ops-root.sh` checks the `.apexyard-fork` marker first, then falls back to the legacy `onboarding.yaml + apexyard.projects.yaml` pair for un-migrated forks. Moving `onboarding.yaml` out of the public fork removes the legacy anchor, so an operator who accidentally deletes `.apexyard-fork` after migration leaves the fork un-resolvable — until they manually `cp` the sibling-repo copy back.
2. **`/split-portfolio` produces a v1 layout.** The single-fork → split-portfolio migration skill only handled the registry + `projects/` (the v1 file classes). Adopters who ran `/split-portfolio` after framework #242 landed in a fresh v1 layout, then had to run `/update` to reach v2 — a two-step migration where one was enough.

### Refined semantics (per file class)

| File class | Migration verb | Why |
|---|---|---|
| `onboarding.yaml` | **COPY** (`cp -p`) + `git rm --cached` from public fork + add to `.gitignore` | Small (KB). Legacy ops-root walk-up still reads it as a fallback anchor (`_lib-ops-root.sh`). The public-fork copy is left on disk as a snapshot — gitignored so it can't drift into commits, but available as a safety net if the sibling repo is unreachable or the `.apexyard-fork` marker is accidentally removed. The sibling-repo copy is the **canonical source of truth**; `/setup` writes to it, `/handover` reads from it. |
| `workspace/<name>/` | **MOVE** (`mv`) | Clones are gigabytes. Doubling disk has no compensating benefit — there's no legacy code path that reads the public-fork copy, no safety net case that benefits, and the cost (gigabytes of duplicated git history) is real. `workspace/README.md` (framework artefact explaining the convention) stays in the public fork per § G. |

### Post-state (after a clean v1→v2 migration)

```
PUBLIC FORK                                  SIBLING PRIVATE REPO
.apexyard-fork                  ←─ marker    onboarding.yaml          ← canonical
onboarding.yaml                 ←─ snapshot  workspace/
  (gitignored, untracked)                      <project-1>/
workspace/                                     <project-2>/
  README.md (kept)                             ...
.gitignore                      ← extended  apexyard.projects.yaml
.claude/project-config.json     ← v2 keys   projects/
                                              ...
```

The public fork has a snapshot of `onboarding.yaml` plus everything it needs to keep working under both the v2 anchor (`.apexyard-fork`) and the legacy fallback. The sibling repo has the canonical copies that every tool writes to going forward.

### Where this refinement lands

| File | Change |
|---|---|
| `.claude/skills/split-portfolio/SKILL.md` Steps 9a–9d | New sub-steps that produce the v2 layout in a single skill invocation. Without this, `/split-portfolio` landed adopters on v1 and they had to run `/update` to finish the migration. |
| `.claude/skills/update/SKILL.md` Step 8a | `onboarding.yaml` switches from `mv` to `cp -p` + `git rm --cached`. `workspace/` stays as `mv`. The per-file-class confirmation prose updates accordingly. |
| `.claude/hooks/tests/test_split_portfolio_v2_migration.sh` | Case 1 assertions extended (both copies of `onboarding.yaml` exist, contents are identical, public-fork copy is untracked, `.gitignore` carries the entry). New Case 4 explicitly pins the copy-not-move semantics. Case 2 (idempotence) extended to cover the new copy path. `workspace/` assertions unchanged. |

### What we are explicitly NOT doing

- **No re-tracking the public-fork `onboarding.yaml` later.** Once gitignored, it stays gitignored. The sibling-repo copy is canonical forever.
- **No copy-semantics for other file classes** (`apexyard.projects.yaml`, `projects/`, etc.). Those went to the sibling under v1 already and there's no legacy fallback that wants them in the public fork.
- **No symmetry-for-its-own-sake.** Adopters who think the two file classes should use the same verb are welcome to file an issue; the asymmetry is deliberate and we have artefact tests that pin it.

## Consequences

- Every framework hook that walks for ops-root now checks `.apexyard-fork` first, then falls back to the legacy pair. Walk-up cost on v2-migrated forks drops to a single `stat`.
- Adopters who manually delete `.apexyard-fork` after migration will appear to walkers as un-configured forks. Mitigation: the filename includes "apexyard"; operators have to actively delete it. README in `docs/multi-project.md` § "Where session-state files live" notes the file's purpose.
- The legacy `onboarding.yaml + apexyard.projects.yaml` walk-up condition stays load-bearing for un-migrated adopters. No deprecation window is set; we can sunset it in a later release once telemetry shows the legacy path isn't hit.
- `/update` step 8a's migration is idempotent: re-running on a v2 layout is a no-op (files already in private repo → `mv` block skips; marker already present → `touch` is a no-op; config-block keys already set → `jq` merge preserves existing values). Idempotence is asserted in test case 2 of `test_split_portfolio_v2_migration.sh`.
- Per-file-class y/n means adopters can defer one migration class (e.g. migrate `onboarding.yaml` now, defer `workspace/`). Walkers handle the half-migrated state via the legacy fallback.
- The "no symlink for v2 additions" decision means adopters on symlink-mode (framework < #145) must upgrade to the config block before opting into v2. Documented in the v2 migration section of `docs/multi-project.md`.
- `workspace/README.md` special-case lives in two places (skill + manual recipe). Keeping them in sync is a maintenance burden; both have a comment pointing at this AgDR.

## Artifacts

- Ticket: [me2resh/apexyard#242](https://github.com/me2resh/apexyard/issues/242)
- Implementation PR: feature/GH-242-split-portfolio-v2 → PR #248
- Lib changes: `.claude/hooks/_lib-ops-root.sh`, `.claude/hooks/_lib-portfolio-paths.sh`
- Consumer updates: 7 hooks + `bin/apexyard` + `briefing.sh` + `/handover`
- Migration: `.claude/skills/update/SKILL.md` step 8a
- New-adopter path: `.claude/skills/setup/SKILL.md` step 2b
- Tests: `.claude/hooks/tests/test_ops_root.sh` (new case 8: v2-marker precedence), `.claude/hooks/tests/test_split_portfolio_v2_migration.sh` (13 cases incl. idempotence)
- Docs: `docs/multi-project.md` § "Migrating from split-portfolio v1 to v2"
- Prior art: [AgDR-0010 — Portfolio config + self-healing](AgDR-0010-portfolio-config-and-self-healing.md) (split-portfolio v1), [AgDR-0011 — Bootstrap-skill exemption](AgDR-0011-bootstrap-skill-exemption.md) (related session-state pattern), [#229 + #230 fix](https://github.com/me2resh/apexyard/issues/229) (ops-root walk-up consolidation that introduced `_lib-ops-root.sh`)

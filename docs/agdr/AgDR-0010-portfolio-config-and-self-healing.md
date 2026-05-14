# Portfolio config block + self-healing skill audit + `/split-portfolio` migration helper

> In the context of ApexYard's split-portfolio mode (#143) being functional today only via manual symlinks, with ~16 framework skills hardcoding `apexyard.projects.yaml` and `projects/` as path literals, facing the dual problem that (a) adopters can't reconfigure those paths through the existing config layer and (b) any future skill addition silently re-hardcodes the same paths, I decided to add a `portfolio:` block to the existing `.claude/project-config.json` schema (NOT `onboarding.yaml`), introduce a `_lib-portfolio-paths.sh` helper that resolves `registry`, `projects_dir`, and `ideas_backlog` to absolute paths with single-fork-mode defaults, audit-and-update each affected skill's prose + bash examples to use the helper, ship a SessionStart self-healing banner that surfaces broken portfolio config at session start, and ship a new `/split-portfolio` skill that automates the destructive recovery flow + writes the new config block instead of just symlinks, to achieve first-class config-driven path resolution while preserving zero-behavior-change for every existing adopter who never touches the new block, accepting that this is a single bundled PR closing #145 only (with #146 closed manually post-merge per the single-Closes rule), that the skill audit is mechanical-but-broad (~18 SKILL.md files), and that the migration helper inherits its safety constraints from the underlying force-push + GitHub-timeline-API survival primitives (no way to make timeline survival truly reversible).

## Context

PR #144 (merged into `dev` 2026-05-03) shipped the docs + `/setup` privacy gate but explicitly deferred the framework primitive. Today's split-portfolio adopters set up two symlinks (`apexyard.projects.yaml` → `../portfolio/...`) and the existing skills resolve transparently. That works, but:

1. **New skill additions don't know there's a configurable path** — the next contributor will hardcode `apexyard.projects.yaml` again.
2. **Adopters who want a non-symlink layout** (e.g. registry on a network drive, projects in a separate parent dir) have no escape hatch.
3. **The `/setup` skill in #144 hand-creates symlinks**; a `/split-portfolio` skill that automates the full destructive recovery flow (#146) needs the config primitive to land somewhere clean, not pile on more symlink writes.
4. **No proactive failure surface.** A typo in `portfolio.registry` (or a stale path after the adopter moves the sibling portfolio repo) only surfaces when the next portfolio-aware skill is invoked, with a confusing downstream error.

The existing config layer (`.claude/project-config.{defaults,}.json` + `_lib-read-config.sh` + `config_get_or`, with 6+ hooks already using it) is the right home — it already supports per-fork overrides, ships an `_lib-` shared library pattern, and provides shallow-merge semantics with sensible defaults.

## Options

| Option | Pros | Cons |
|--------|------|------|
| Status quo (symlinks only) | Zero work | Every new skill silently re-hardcodes; no escape hatch beyond symlinks; broken config surfaces only at next-skill-invocation |
| `portfolio:` in `onboarding.yaml` (the original ticket wording) | Keeps "company config" colocated | Diverges from existing config pattern; `onboarding.yaml` is for company identity, not runtime path resolution; needs a fresh YAML reader (existing reader is JSON); breaks `config_get_or` precedent |
| **`portfolio:` in `.claude/project-config.json` + `_lib-portfolio-paths.sh` helper + `portfolio_validate` self-heal + skill audit + `/split-portfolio` skill (CHOSEN)** | Reuses existing config-loader infrastructure; six hooks already follow this pattern; adopters who customize one config file customize them all; self-healing surfaces broken config at session-start instead of skill-invocation-time; `/split-portfolio` produces clean config-block migration | Skill audit is broad (~18 SKILL.md files); single Closes-keyword constraint means #146 closed manually post-merge |
| Helper-only, no schema (resolve through git rev-parse + symlink-detection) | Smallest diff | Doesn't actually solve "first-class config" — still implicit; symlinks remain the only mechanism |
| Refactor every skill to a Python utility | Better testability | Massive scope expansion; most skills are bash-heavy by design; doesn't match the framework's existing conventions |

## Decision

Chosen: **`portfolio:` block in `.claude/project-config.{defaults,}.json` + helper library + self-healing SessionStart hook + skill audit + new `/split-portfolio` skill, all in one bundled PR.**

Three reasons it wins:

1. **Reuses existing patterns.** Adopters who already configured `leak_protection` or `ticket` or any of the other config blocks already understand this. Single conceptual model.
2. **Self-healing surfaces failures early.** A broken `portfolio.registry` path no longer waits until next-skill-invocation — it shows at session start. Same shape as the existing `check-upstream-drift.sh` banner: silent on success, loud on failure, never blocks the session.
3. **`/split-portfolio` ships the migration as code, not docs.** The recovery flow is destructive enough (force-push, body redaction) that a documented step-list is genuinely error-prone. A skill captures the right sequence, the operator-confirmation gates at every destructive step, the timeline-API survival caveat, and the idempotent re-run path.

## Scope summary

### 1. Schema — `.claude/project-config.defaults.json`

Adds a `portfolio:` block with `registry`, `projects_dir`, `ideas_backlog`. Defaults preserve today's single-fork behavior (relative paths, fork-rooted).

### 2. Helper — `.claude/hooks/_lib-portfolio-paths.sh`

Sourceable shell library exposing:

- `portfolio_registry()` — absolute path to registry
- `portfolio_projects_dir()` — absolute path to projects dir
- `portfolio_ideas_backlog()` — absolute path to ideas backlog
- `portfolio_validate()` — structured "OK / broken / why"
- `portfolio_clear_cache()` — test helper

Path resolution walks up to find the ops-fork root (dir with `onboarding.yaml + apexyard.projects.yaml`), resolves relative paths against it, outputs absolute. Falls back to git toplevel outside an apexyard fork. Cached per-process (matching `_CONFIG_CACHE` pattern in `_lib-read-config.sh`).

### 3. Self-healing — `check-portfolio-config.sh` SessionStart hook

Silent when valid; one-line banner on failure naming the broken field + suggested fix. Never blocks the session.

### 4. Skill audit — 18 SKILL.md files

Adds a "Path resolution" callout to every skill that touches the registry / projects_dir / ideas_backlog paths. Each callout points at the helper. Two skills got deeper bash-block edits:

- `handover/SKILL.md` — `yq eval -i ... apexyard.projects.yaml` blocks now source the helper + use `$(portfolio_registry)`.
- `setup/SKILL.md` Step 2b — writes the `portfolio:` config block (recommended) instead of symlinks; symlinks remain documented as legacy fallback.

### 5. New skill — `.claude/skills/split-portfolio/SKILL.md`

10-step migration flow with explicit operator-confirmation gates. `--verify` mode for read-only state report. `--dry-run` mode prints commands without executing. Refuses on already-private fork, paid GitHub plan, dirty working tree, or already-migrated state.

### 6. Doc updates — `docs/multi-project.md`

- Layout section updated to describe both modes (config-block recommended, symlink legacy).
- Setup steps split into "config-block mode (recommended)" and "symlink-based mode (framework < #145)".
- Migration section replaced with `/split-portfolio` skill invocation; manual steps preserved as fallback.

### 7. Tests — `.claude/hooks/tests/test_portfolio_paths.sh`

13 cases covering: defaults resolve correctly; absolute override wins; relative override resolves against fork root; missing-registry, missing-projects-dir, missing-ideas-backlog-with-bad-parent all → broken; ideas-backlog missing-but-creatable → OK; cache + clear_cache contract.

## Consequences

### Positive

- **Zero behavior change for existing single-fork adopters.** Defaults match today's hardcoded values exactly. Verified by smoke: a fresh fork with no `portfolio:` override produces identical paths.
- **Split-portfolio adopters can drop symlinks** (or keep them — the helper resolves either way). Both modes coexist; no forced migration.
- **`/split-portfolio` automates the full recovery** instead of leaving the adopter mid-flow with a manual checklist.
- **New skill contributions follow the helper pattern**, not the literal-string anti-pattern. Each new skill that touches the registry includes the "Path resolution" callout from the existing convention.
- **Self-healing surfaces broken config at session start**, not at next-skill-invocation. Adopter sees a clear "registry resolved to X — file does not exist" message instead of a downstream skill failing with "couldn't read registry".

### Negative

- **PR is broad.** ~18 SKILL.md files updated mechanically (callout insertion). Diff is mostly the same paragraph repeated — but it spans the framework. Mitigation: the callout is identical across files (verified by grep), and the heavier handover/setup edits are isolated to two files.
- **Two tests at minimum.** `_lib-portfolio-paths.sh` helper covered by 13 unit cases. `/split-portfolio` is integration-only by nature; no automated test for the destructive flow — relies on manual operator-confirmed smoke. Documented in the skill's AC list.
- **Single Closes-keyword constraint** means PR closes #145 only; #146 is closed manually after merge with a "delivered in PR #X" comment. Not a clean tracker shape, but follows the framework's own rule.
- **Self-healing helper cost.** SessionStart adds one `portfolio_validate` call per session. Measured: ~10-30ms when yq is available (one parse of the registry); ~1ms when not. Acceptable.
- **Path-resolution callout duplicated across skills.** Future cleanup could extract to a single shared `.claude/skills/_shared-conventions.md` with each SKILL.md linking to it. Out of scope here; tracked as future cleanup if it becomes a maintenance burden.

### Reversibility

- Helper + schema + SessionStart hook fully reversible. Remove the `portfolio` block, delete the helper, revert SKILL.md callouts, remove the SessionStart wiring.
- `/split-portfolio` is purely additive — drop the skill directory.
- The single irreversible thing in this entire PR is what `/split-portfolio` does to a fork's GitHub timeline API on a real migration run. That's inherent to the underlying `gh` operations, not introduced by this PR.

## Future phases (NOT in this AgDR)

- **Extract the path-resolution callout** to a single shared `.claude/skills/_shared-conventions.md` file if the duplication becomes a maintenance pain point. Currently 18 copies of the same paragraph.
- **Python helper parallel to the shell helper** if any skill ever needs to call the resolver from a Python context. Not needed today; all current callers are bash.
- **Per-skill `portfolio_validate` calls** beyond `/setup` — e.g. `/handover`, `/inbox` could opt into validating before doing path-touching work. Currently relies on the SessionStart banner + skill-natural-error-surfacing.
- **`--force` flag for `/split-portfolio`** to override the "already private" / "paid plan" refusals. Deliberately not v1; require ask-first interaction.

## Artifacts

- Branch: `feat/GH-145-portfolio-config-and-helper`
- Tickets: me2resh/apexyard#145 (closed by PR), me2resh/apexyard#146 (closed manually post-merge)
- Predecessor: me2resh/apexyard#144 (docs + `/setup` privacy gate, merged into `dev` 2026-05-03)
- Related AgDRs: AgDR-0006 (project-configurable ticket schema — same config-block convention this AgDR extends), AgDR-0009 (voice prompts — same default-OFF / opt-in-via-config pattern), AgDR-0001 (rule-mechanization-hooks — establishes SessionStart as the right shape for proactive notice).

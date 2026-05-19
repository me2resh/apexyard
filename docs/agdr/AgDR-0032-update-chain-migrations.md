---
id: AgDR-0032
timestamp: 2026-05-19T00:00:00Z
agent: claude
model: claude-opus-4-7
trigger: ticket #282
status: executed
---

# `/update` walks the per-version migration chain

> In the context of adopters who fork apexyard and may sync after multiple
> framework releases have shipped (e.g. v1.0.0 → v1.4.0 in one go), facing
> the problem that one-hop `/update` silently dropped them past per-release
> migration steps (split-portfolio v1→v2, future template reorgs, etc.),
> I decided to introduce a per-release migration directory + file-based
> version anchor + chain-walking flow in `/update`,
> to achieve a deterministic "every adopter eventually runs every migration"
> guarantee with operator-confirmable per-step prompts,
> accepting that the framework now owes a migration script (real or no-op)
> at every release cut and that adopters pre-anchor need a one-time
> interactive prompt to bootstrap.

## Context

- Today's `/update` pulls `upstream/main` (latest release tag) and lands its files in the fork's working tree, with an in-flow step 8a that detects the legacy split-portfolio v1 layout and offers the migration.
- That one-shot step was the only per-release migration the framework had to deal with — until v1.4.0, which adds a templates-reorg migration (#281), and future releases that will add their own.
- An adopter on v1.0.0 who runs `/update` to land v1.4.0 would silently skip three intermediate releases of migration steps. The CHANGELOG documents them, but there's no replay path other than reading each release's "notable behaviour changes" section by hand.
- The framework lives on `upstream/main` as a release-only stream (AgDR-0007). Tags are stable signals; commit SHAs and merge histories aren't, because adopters routinely rebase / squash-merge.
- Ticket #282 spelled out the requirements: per-version scripts, idempotent, per-file-class confirmable, four exit-code contract, operator-overridable version anchor, optional `--skip-migrations`.

## Options Considered

### Where does the "current version" anchor live?

| Option | Pros | Cons |
|--------|------|------|
| **A. File at `.claude/framework-version` (CHOSEN)** | One line, one job; trivial to read/write; robust to history rewrites; visible in `git status` after `/update` advances it | Adds one tracked file; adopters who delete it lose the chain start (mitigated by interactive bootstrap prompt) |
| B. Derive from the most recent merge-from-upstream commit's tag | Zero new files | Fragile under squash-merge, rebase, `/update --rebase`; silent drift; relies on a stable tag-on-commit story that adopters don't always preserve |
| C. `framework_version` key in `.claude/project-config.json` | Lives next to existing config | Mixes a *measured* fact with *configured* facts; adopters edit project-config by hand and risk stale values; partial-merge across the existing override block is awkward |

### How do per-release migrations get expressed?

| Option | Pros | Cons |
|--------|------|------|
| **A. Per-pair shell scripts in `.claude/migrations/` named `v<from>-to-v<to>.sh` (CHOSEN)** | Bounded to one transition; replayable in isolation; chain shape is git-visible; new releases add one file or one no-op placeholder | Discipline at release-cut: skipping a release means the chain refuses to walk past it (mitigated by `/release` skill template) |
| B. One monolithic `migrate.sh` with internal version-routing | Fewer files | Hard to bisect failures across releases; hard to replay a single step; opaque diff at release time |
| C. Markdown-described migrations in CHANGELOG.md that adopters run by hand | Already documented | Adopters routinely skip migrations; the framework gets blamed for "silent" misses; defeats the whole point of the ticket |

### How does the operator confirm each migration?

| Option | Pros | Cons |
|--------|------|------|
| **A. Per-step `[Y / n / show-diff / skip-all]` prompt (CHOSEN)** | Matches the existing `/split-portfolio` per-file-class shape; lets adopter inspect before applying | Slightly more friction than auto-apply |
| B. Auto-apply with post-hoc diff | Fastest path | Operator owns each material change is the framework's stance everywhere else; surprising auto-application breaks that |
| C. Apply all-or-nothing | Single yes/no | Loses per-step granularity; one failing migration aborts everything even when later ones would succeed independently |

## Decision

**Chosen**:

1. **File anchor** at `<ops_fork>/.claude/framework-version`, single-line `vMAJOR.MINOR.PATCH`. Written by `/update` after a successful sync. `migration_current_version` returns "unknown" when missing OR malformed.
2. **Per-pair shell scripts** at `.claude/migrations/v<from>-to-v<to>.sh`. Seeded with two real scripts: `v1.2.0-to-v1.3.0.sh` (the split-portfolio v1→v2 recipe extracted from `/update` step 8a) and `v1.3.0-to-v1.4.0.sh` (placeholder for v1.4.0-cycle migrations).
3. **Chain walking helper** at `.claude/hooks/_lib-migration-chain.sh`. Exposes `migration_current_version`, `migration_write_anchor`, `migration_known_versions`, `migration_chain <from> <to>`, `migration_run <pair>`, `migration_script_path <pair>`. Greedy walk: start at `<from>`, advance by matching `<current>-to-v...` pairs, stop at `<to>`. Refuses with empty output on missing link OR backwards walk.
4. **Per-step confirmable prompt** in `/update` step 8b, matching the `/split-portfolio` shape.
5. **Two new flags**: `--from-version vN.N.N` (override anchor) and `--skip-migrations` (advance anchor only). `--from-dev` automatically skips the chain (pre-release has no tag).

The chain script contract is the four-exit-code shape from the ticket:

- `0` — applied OR skipped (success either way)
- `1` — conflict requires operator (chain pauses; anchor NOT advanced)
- `2` — hard error (chain aborts; anchor NOT advanced)

## Consequences

**Kept:**

- The existing one-shot step 8a (split-portfolio v1→v2) stays in place as a fallback for adopters who lack the version anchor entirely. The chain-script `v1.2.0-to-v1.3.0.sh` IS the same recipe, factored out — both paths converge on the same end state.
- All existing `/update` flags (`--rebase`, `--dry-run`, `--from-dev`).
- The "operator owns each material change" stance — chain steps are individually confirmable.

**Added:**

- `.claude/migrations/` directory + two seed scripts + README.
- `.claude/hooks/_lib-migration-chain.sh` (5 public functions + 1 helper).
- `/update` step 8b (chain walk).
- `/update --from-version` + `/update --skip-migrations` flags.
- `.claude/framework-version` anchor file (written on first successful `/update` post-#282).
- `docs/upgrading.md` adopter-facing reference.
- Test suite at `.claude/hooks/tests/test_update_chain.sh` (11 cases).

**Dropped:**

- The "silently miss per-release migrations" failure mode.

**Discipline added:**

- Every release that goes out MUST land a migration script — real or no-op placeholder. The `/release` skill template will gain a checklist item to enforce this; CHANGELOG-level mention isn't sufficient because the chain refuses to walk past a missing pair.
- Adopters who delete `.claude/framework-version` get an interactive bootstrap prompt with the known-version menu the next time they run `/update`. One-time cost.

**Non-consequences (explicit):**

- The chain walker does **not** handle cross-repo migrations beyond the well-known sibling private repo (split-portfolio v2 layout). A migration that needs to touch managed-project clones is out of scope.
- Pre-release work (`--from-dev`) is intentionally excluded from the chain — dev has no release tag. Adopters on dev are signing up for breakage between releases (AgDR-0007).
- No automatic rollback. If a migration goes wrong mid-walk, the operator restores the working tree manually and re-runs.

## Artifacts

- Implementing ticket: `me2resh/apexyard#282`
- Library: `.claude/hooks/_lib-migration-chain.sh`
- Migrations dir: `.claude/migrations/{README.md, v1.2.0-to-v1.3.0.sh, v1.3.0-to-v1.4.0.sh}`
- Skill update: `.claude/skills/update/SKILL.md` (step 8b + new flags + design notes)
- Tests: `.claude/hooks/tests/test_update_chain.sh` (11 cases)
- Adopter doc: `docs/upgrading.md`
- Doc update: `docs/multi-project.md` § "Upgrades — pulling from upstream"

# Reconcile installed Codex adapters during framework updates

> In the context of `/update` synchronising ApexYard's canonical `.claude/`
> runtime while Codex consumes generated `.agents/` and `.codex/` output,
> facing the need to refresh existing Codex installations without creating
> Codex files for adopters who do not use that harness, I decided to make the
> Codex generator emit a static ownership manifest and have `/update`
> reconcile manifest-backed or recognisable legacy installations before every
> successful exit, to achieve automatic adapter freshness with an explicit
> installation boundary, accepting one generated metadata file and a narrow
> compatibility fallback for adapters created before the manifest exists.

## Context

- `.claude/` is the canonical ApexYard runtime; `bin/sync-codex-adapter.sh`
  derives Codex skills, agents, and hook wiring from it under `.agents/` and
  `.codex/`.
- `/update` currently exits immediately when framework refs are current, so a
  generated adapter can remain on the previous release even though no Git
  synchronization remains to perform.
- Unconditional generation would create Codex-specific files for adopters who
  use only Claude Code or another harness. Detection therefore needs to answer
  whether ApexYard owns an installed Codex adapter, not which app launched the
  current session.
- Existing Codex installations predate any ownership manifest, so a manifest-
  only check would repair new installations but strand current adopters on the
  exact stale state this change is intended to fix.
- The `/update` skill is itself generated into `.agents/skills/update/`. An
  adopter running a pre-fix copy cannot execute reconciliation instructions
  that exist only in the newly merged canonical skill, so the first upgrade
  needs a bootstrap path outside that stale prompt.
- Existing generated Codex hook wiring already delegates the SessionStart
  `check-upstream-drift.sh` command to its canonical `.claude/hooks/` path.
  After a framework sync, that stable command can therefore run newly merged
  reconciliation logic even while `.codex/hooks.json` is stale — but a
  SessionStart hook fires on *every* session, so it must never itself mutate
  the working tree; it can only advise the operator to run the real, explicit
  reconciliation path.
- Reconciliation deletes and replaces owned output paths (`.agents/skills`,
  `.codex/agents`, `.codex/hooks.json`, `.codex/apexyard-adapter.json`). A
  whole-tree comparison against `.agents/` or `.codex/` would misclassify any
  hand-authored file living alongside the generated output (a native Codex
  `config.toml`, a runtime cache) as drift, producing false-positive warnings
  and — worse — a false-positive hard failure on `/update`'s strict path.
  Drift detection therefore needs to be scoped to exactly the paths the
  adapter owns, not the whole directory.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| Unconditionally run the Codex generator on every `/update` | Simple; every fork receives fresh Codex output | Creates `.agents/` and `.codex/` for adopters who never installed Codex support; makes harness choice implicit |
| Infer installation only from generated directories | Repairs existing installs without new metadata | A partial or user-owned `.agents/` / `.codex/` tree is ambiguous; there is no durable ownership or schema signal |
| Require a generated ownership manifest and ignore legacy output | Precise and extensible installation boundary | Existing pre-manifest adapters never self-heal unless operators manually regenerate once |
| Emit a generated ownership manifest, with a complete-shape legacy fallback | Precise for future runs; repairs existing installations; leaves uninstalled forks untouched | Carries one generated metadata file and temporary compatibility logic |

## Decision

Chosen: **emit a generated ownership manifest and recognise the complete legacy
Codex adapter shape as a compatibility fallback**, because `/update` needs a
durable, harness-specific ownership signal without abandoning adapters generated
before that signal shipped.

`bin/sync-codex-adapter.sh` will emit `.codex/apexyard-adapter.json` with a
stable adapter identifier, schema version, and canonical source. The manifest
is generated output and participates in the existing `--check` comparison, so
its absence or drift is reported like any other adapter output.

The generator will expose an idempotent installed-only reconciliation mode
(`--reconcile-installed`, mutating) and a companion read-only staleness check
(`--check-installed`), so `/update`, the SessionStart advisory, and any manual
invocation share one detection and generation implementation. Both are a
silent no-op when no ApexYard Codex installation is detected; the mutating
mode fails non-zero when generation or verification fails, and the read-only
mode fails non-zero when the installed adapter has drifted, without ever
writing to disk.

Every drift comparison — `--check`, `--check-installed`, and
`--reconcile-installed`'s own before/after checks — walks only the adapter's
owned relative paths (`.agents/skills`, `.codex/agents`, `.codex/hooks.json`,
`.codex/apexyard-adapter.json`), never a whole-tree `diff -qr` of `.agents/`
or `.codex/`. A file outside that owned list is invisible to drift detection
and is never touched by reconciliation.

Because reconciliation deletes and replaces generated paths, the generator
must reject symlinked `.agents` / `.codex` roots and symlinked owned child paths
before reading installation metadata or mutating output. This prevents a
repository-controlled adapter path from redirecting a reconciliation write
outside the repository.

`/update` will consider Codex installed when either:

1. `.codex/apexyard-adapter.json` identifies the ApexYard Codex adapter; or
2. the legacy generator's complete shape exists: `.agents/skills/`,
   `.codex/agents/`, and `.codex/hooks.json`.

On a successful framework sync, reconciliation runs after canonical files and
migrations are settled. On the already-current path, it runs before the early
exit. `--dry-run` remains read-only, and `--skip-adapter-sync` provides an
explicit troubleshooting escape hatch. Reconciliation runs the generator and
then `--check`; generation or verification failure makes `/update` fail loudly
instead of reporting a successful update with stale governance output.

For visibility between explicit `/update` runs, the already-wired
`check-upstream-drift.sh` SessionStart hook invokes the generator's
**read-only** `--check-installed` mode before any of its normal silent exits.
This is an advisory nudge, not a second reconciliation implementation, and it
never mutates the tree: on drift it prints a one-line warning naming
`bin/sync-codex-adapter.sh --reconcile-installed` as the fix, wrapped in the
same `timeout`-guarded pattern as the hook's sibling `git fetch` call so a
hung generator invocation can't stall session startup. The hook remains
silent on success/no-install, reports a concise warning on drift or failure,
and does not block session startup. The actual reconciling write only ever
happens through explicit `/update` or a manual `--reconcile-installed`
invocation — never automatically at session boot.

Verification is split across the existing generator smoke test and a dedicated
`/update` reconciliation test. Together they must prove:

- the manifest is generated, schema-valid, and included in `--check` drift
  detection;
- manifest-backed and complete-shape legacy installations are detected, while
  an uninstalled fork and every partial legacy shape remain untouched;
- the already-current path refreshes stale output before reporting success;
- the post-sync path invokes the same reconciliation contract after canonical
  files settle;
- `--dry-run` and `--skip-adapter-sync` do not mutate adapter output; and
- generation or verification failure propagates as a non-zero `/update`
  result instead of being downgraded to a warning;
- the existing SessionStart wiring reaches the canonical `--check-installed`
  call, which leaves an uninstalled fork untouched, never mutates an installed
  one, and warns without blocking when the adapter has drifted or the check
  itself fails;
- symlinked adapter roots and owned child paths fail before mutation, with
  external sentinel files proving that reconciliation cannot escape the repo;
- drift detection ignores files outside the adapter's owned paths (a
  hand-authored file living alongside the generated output must not be
  reported as drift or be at risk of deletion).

## Consequences

- Existing Codex adopters receive new skills, agent definitions, and hook
  wiring automatically the next time they run `/update`, including when Git is
  already current.
- Adopters with no detected Codex installation see no new `.agents/` or
  `.codex/` files.
- The first reconciliation of a legacy adapter writes the manifest, after
  which future detection no longer relies on directory shape.
- A pre-fix generated `$update` gets a visible SessionStart nudge as soon as
  the framework files land, but reconciliation itself still requires an
  explicit `/update` run or a manual `--reconcile-installed` invocation — the
  hook only ever advises, it does not self-heal the installation at boot.
- A user-owned partial `.agents/` or `.codex/` tree is not treated as an
  ApexYard installation; all three legacy output surfaces must be present.
- Symlinked generated roots or critical output children are rejected for every
  generator mode; automatic reconciliation never follows them.
- Generated tracked output may become dirty after reconciliation by design;
  that is the visible update an adopter should review and commit. Ignored local
  output refreshes without changing Git state.
- Drift detection and reconciliation are scoped to the adapter's owned paths
  only, so a hand-authored file living alongside generated output under
  `.agents/` or `.codex/` is never flagged as drift and never deleted.
- The same manifest pattern can be adopted by other generated harness adapters
  later, but this decision does not claim they share Codex's generation or
  installation lifecycle.
- `check-upstream-drift.sh` gains one local, read-only, timeout-guarded
  staleness check before its network/tag logic. That expands its startup
  responsibility slightly, but the check never mutates the tree — it reuses an
  already-delegated canonical execution seam purely to surface a warning, not
  to perform the reconciliation itself.

## Artifacts

- Ticket: [me2resh/apexyard#943](https://github.com/me2resh/apexyard/issues/943)
- Prior decision: [AgDR-0088](AgDR-0088-codex-adapter-generation.md)
- Generator: `bin/sync-codex-adapter.sh`
- Update skill: `.claude/skills/update/SKILL.md`

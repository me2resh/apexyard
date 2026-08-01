# `.claude/migrations/` — per-release migration scripts

This directory holds one shell script per **framework version transition**. `/update` walks the chain from the adopter's recorded framework version to the latest release tag and runs each script in order, with per-step confirmation.

See `docs/upgrading.md` for the adopter-facing flow and `docs/agdr/AgDR-0032-update-chain-migrations.md` for the design rationale.

## Filename convention

```
v<from>-to-v<to>.sh
```

`<from>` and `<to>` are semver-core (`vMAJOR.MINOR.PATCH`, no pre-release suffix). Examples:

- `v1.2.0-to-v1.3.0.sh` — runs when an adopter on v1.2.0 syncs past v1.3.0
- `v5.2.0-to-v5.3.0.sh` — runs when an adopter on v5.2.0 syncs past v5.3.0

The chain walker (`.claude/hooks/_lib-migration-chain.sh`) discovers pair scripts by globbing this directory; the filenames ARE the chain.

## Script contract

Each script must:

| Requirement | Why |
|-------------|-----|
| **Idempotent** | `/update` may re-run after an interrupted sync; running twice is safe. Guard each mutation on "source present AND target absent". |
| **Stage, don't commit** | `git add` the touched files. The operator owns the commit message (matches the rest of `/update`'s "operator owns each material change" stance). |
| **Per-file-class confirmable** | If your migration touches more than one class of file (e.g. "move X" AND "move Y"), use `APEXYARD_MIGRATION_PROMPT=onboarding\|workspace\|none\|yes` to let the operator opt in/out per class. Same pattern as `/split-portfolio`. |
| **Exit codes**: 0=applied/skipped, 1=conflict needs operator, 2=hard error | `/update` reads the code to decide whether to continue, pause, or abort. |
| **Quiet mode**: respect `APEXYARD_MIGRATION_QUIET=1` | Lets tests suppress informational stdout without losing real errors. |

## What goes in a migration script

The class of work `/update` is good at automating:

- Moving files between gitignored regions (e.g. `/split-portfolio` v1→v2)
- Adding default keys to `.claude/project-config.json`
- Writing presence-only marker files
- Updating `.gitignore` entries
- Renaming directories that match a stable pattern (e.g. `custom-templates/x.md` → `custom-templates/tickets/x.md`)

What does **not** belong here:

- Anything that needs human judgement on the diff (interpreting adopter customisations against new defaults — that's the `_lib-detect-deprecated-config.sh` flow with its y/n/s offer)
- Anything that crosses repo boundaries beyond the well-known sibling private repo (we know about `<ops_fork>/../<sibling>-portfolio`; we don't know about your other clones)
- Anything irreversible without an explicit operator-confirmation prompt

## Authoring a new migration

When cutting a release that needs a per-adopter migration:

1. Create `v<current>-to-v<next>.sh` in this directory.
2. Make it executable (`chmod +x`).
3. Add a row to `docs/upgrading.md`'s "What each migration does" table.
4. The release PR's CHANGELOG entry calls out the new migration.

If the new release has **no** per-adopter migration, **still create the script as a no-op** (`v5.2.0-to-v5.3.0.sh` is the template — see also the `/release` skill's step 3b migration-script check, which warns if you forget). Skipping a release in the chain would force an earlier adopter to jump over the gap — `migration_chain` refuses that and emits empty output, defeating the whole walk.

## Orphaned hop scripts (target never tagged)

If a release you were planning gets renamed, folded into another version, or
cancelled before it ships, its `v<current>-to-v<planned>.sh` placeholder
becomes an **orphan** — a script naming a `<to>` version that will never
exist as a git tag. `migration_known_versions` (used to build the
"unknown anchor" interactive menu) reads pair filenames literally, so an
orphaned script silently offers a nonexistent version as a menu choice, and
`migration_chain` walks *into* the fake version and then reports the wrong
version as the point where the chain broke.

When you discover an orphan (a script whose `<to>` side has no matching git
tag): **remove it**, don't rename it forward to whatever tag actually shipped
next. A no-op placeholder for `vA-to-vB` is a claim that nothing needed doing
between `vA` and `vB`; renaming an orphan to `vA-to-v<real-next>` reuses that
claim for a hop it was never written to describe, and — especially across a
MAJOR bump — that's not a claim you can make without checking the actual
release. Removing the orphan leaves a real gap (chain refuses at `vA`, per
the missing-link edge case above) instead of a false all-clear; back-fill the
real hop with its own reviewed no-op or real script once you've checked what
that release actually needed. See me2resh/apexyard#1105 for the case that
prompted this — `v1.3.0-to-v1.4.0.sh` outlived a v1.4.0 that was never
tagged (v2.0.0 shipped in its place).

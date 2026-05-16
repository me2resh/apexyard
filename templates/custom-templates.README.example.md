# Custom Templates

This directory holds **adopter-authored overrides** for the framework's markdown templates. Overrides are **framework-wide** (not per-project) and **replace** the framework default in full (not additive).

## Path convention

Mirror the framework's `templates/<path>` shape. If you want to override `templates/prd.md`, put your version at `custom-templates/prd.md`. For nested paths like `templates/architecture/c4-context.md`, mirror the directory structure: `custom-templates/architecture/c4-context.md`.

| Framework default | Your override here |
|--------------------|---------------------|
| `templates/prd.md` | `custom-templates/prd.md` |
| `templates/agdr.md` | `custom-templates/agdr.md` |
| `templates/agdr-migration.md` | `custom-templates/agdr-migration.md` |
| `templates/spike.md` | `custom-templates/spike.md` |
| `templates/architecture/c4-context.md` | `custom-templates/architecture/c4-context.md` |
| `templates/architecture/c4-container.md` | `custom-templates/architecture/c4-container.md` |

## Override semantics

An authored override **replaces** the framework default — partial overrides aren't supported. Copy the framework version in full, then edit your copy. When the framework ships an updated template, your override doesn't pick up the change automatically; diff your version against the new framework default when you `/update`.

## How resolution works

Every template-consuming skill (`/decide`, `/write-spec`, `/c4`, `/migration`, `/spike`, `/handover`) routes through `portfolio_resolve_template` from `.claude/hooks/_lib-portfolio-paths.sh`:

1. If `<this_dir>/<path>` exists → use it.
2. Else if `<ops_root>/templates/<path>` exists → use the framework default.
3. Else the skill returns an error (caller decides what to do).

## What's NOT in scope

- Per-project template overrides (still framework-wide / org-wide only)
- Automatic merging or templating engines (templates stay as plain markdown)
- Encryption (this is a private repo if you put it in one)

## Related

- [`templates/README.md`](../templates/README.md) — full framework-side documentation of the override mechanism
- [`docs/multi-project.md`](../docs/multi-project.md) § "Custom templates" — adopter setup notes
- [`AgDR-0023`](../docs/agdr/AgDR-0023-custom-templates-override-semantics.md) — design rationale

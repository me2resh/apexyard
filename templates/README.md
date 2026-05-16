# Templates

ApexYard ships markdown templates under `templates/` that consuming skills read at invocation time — `/decide` reads `agdr.md`, `/write-spec` reads `prd.md`, `/c4` reads `architecture/c4-context.md` and `architecture/c4-container.md`, `/migration` reads `agdr-migration.md`, `/spike` reads `spike.md`, `/handover` reads `architecture/c4-container.md`. The full inventory is in [`CLAUDE.md` § "Templates"](../CLAUDE.md).

## Adopter overrides — the `custom-templates/` layer

Every framework template can be overridden by an adopter-authored version. The override mechanism is **path-mirroring** — no frontmatter, no config table, no registry. If you want to override `templates/<path>`, drop your version at `<private_repo>/custom-templates/<path>`.

| Framework default | Adopter override location |
|--------------------|---------------------------|
| `templates/prd.md` | `<private_repo>/custom-templates/prd.md` |
| `templates/agdr.md` | `<private_repo>/custom-templates/agdr.md` |
| `templates/agdr-migration.md` | `<private_repo>/custom-templates/agdr-migration.md` |
| `templates/spike.md` | `<private_repo>/custom-templates/spike.md` |
| `templates/architecture/c4-context.md` | `<private_repo>/custom-templates/architecture/c4-context.md` |
| `templates/architecture/c4-container.md` | `<private_repo>/custom-templates/architecture/c4-container.md` |
| `templates/architecture/vision.md` | `<private_repo>/custom-templates/architecture/vision.md` |
| any nested file `templates/<a>/<b>/<c>.md` | `<private_repo>/custom-templates/<a>/<b>/<c>.md` |

`<private_repo>` is the directory that holds your portfolio registry (`apexyard.projects.yaml`):

- **Single-fork mode** — `<private_repo>` is the ops-fork root itself, so overrides live at `<fork>/custom-templates/<path>`. Same fork, sibling to `templates/`.
- **Split-portfolio mode** — `<private_repo>` is the sibling private repo, so overrides live at `<fork>-portfolio/custom-templates/<path>`. The public fork holds only framework files; your customisations stay private.

## Resolution semantics — override, not additive

Templates are **forms**, not **content**. Overriding them means *replace*, not *append*. If `<private_repo>/custom-templates/prd.md` exists, `/write-spec` uses that file in place of the framework default. The framework's `templates/prd.md` is ignored for that invocation. Two consequences:

1. **You own the whole shape.** Authoring a partial override (e.g. just a different header block, with the rest of the framework's body assumed) doesn't work — the framework can't merge sections from two markdown files reliably. Copy the framework default in full, then edit it.
2. **Future framework updates to that template don't reach you.** When a framework release ships a richer PRD shape, your override won't pick up the change. This is the explicit trade-off — diff your override against the new framework version manually when you `/update`.

## Mechanism — `portfolio_resolve_template`

Skills route through the helper at `.claude/hooks/_lib-portfolio-paths.sh`:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template prd.md)
# → <private_repo>/custom-templates/prd.md if it exists
# → <ops_root>/templates/prd.md otherwise
# → empty + nonzero exit if neither exists (caller decides what to do)
```

Single-fork adopters with no `custom-templates/` dir get the framework default automatically — zero configuration, zero behaviour change.

## Authoring a custom template

1. Pick the framework template you want to customise — e.g. `templates/prd.md`.
2. Copy it to the matching path under your private repo's `custom-templates/`:

   ```bash
   # Single-fork mode:
   mkdir -p custom-templates
   cp templates/prd.md custom-templates/prd.md

   # Split-portfolio mode (run from the public fork):
   mkdir -p ../<fork>-portfolio/custom-templates
   cp templates/prd.md ../<fork>-portfolio/custom-templates/prd.md
   ```

3. Edit the copy to match your company's preferred shape — section headings, default placeholders, internal links to your wiki, whatever.
4. Commit it to the private repo (or to your fork in single-fork mode). The next invocation of the consuming skill picks it up with no extra configuration.

For nested paths like `architecture/c4-context.md`, mirror the directory structure:

```bash
mkdir -p custom-templates/architecture
cp templates/architecture/c4-context.md custom-templates/architecture/c4-context.md
```

## What's NOT in scope

- **Per-project template overrides.** Overrides are framework-wide / org-wide only. If you need a project-specific template, fork the consuming skill instead.
- **Template versioning / migration.** When the framework's template shape changes, you own the diff. Run `/update` periodically and check whether your override still aligns.
- **Variable substitution / templating engines.** Templates are plain markdown with `{placeholder}` text the consuming skill (or you, post-fill) hand-edits. No Jinja, no Handlebars, no compile step.
- **Encrypted custom templates.** Drop them in a private repo if confidentiality matters.

## Related

- [`docs/multi-project.md`](../docs/multi-project.md) § "Custom templates" — adopter-facing setup notes for split-portfolio mode.
- [`AgDR-0023`](../docs/agdr/AgDR-0023-custom-templates-override-semantics.md) — design rationale (override-not-additive, path-mirroring, where overrides live).
- [`templates/architecture/README.md`](architecture/README.md) — guide to the architecture-document templates specifically.

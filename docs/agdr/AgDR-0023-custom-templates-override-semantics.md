---
id: AgDR-0023
timestamp: 2026-05-16T00:00:00Z
agent: claude
model: claude-opus-4-7
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#244
---

# Custom-templates layer: override semantics + path-mirroring discovery

> In the context of split-portfolio adopters wanting to customise framework templates (PRD, AgDR, C4, migration AgDR, spike) without forking the consuming skill, facing the choice between additive merging vs full-replacement and between frontmatter/config-table discovery vs path-mirroring, I decided to ship a `custom-templates/` layer in the private repo with full-replacement override semantics and path-mirroring discovery (resolved by `portfolio_resolve_template`), to achieve "drop a file at the mirrored path and it wins" with zero configuration ceremony, accepting that overriding adopters lose framework template upgrades silently and must diff their override against new framework versions manually when running `/update`.

## Context

- Split-portfolio v2 (#242) put the registry, projects/, onboarding.yaml, and workspace/ into a private sibling repo. That left **templates** as the last adopter-touchable surface still living in the public fork.
- Adopters with company-specific PRD shapes, AgDR styles, or C4 conventions had only one option: fork the consuming skill (`/write-spec`, `/decide`, etc.) — which forks all the surrounding logic, breaking framework upgrades for that skill forever.
- The `_lib-portfolio-paths.sh` helper from #145 + #242 already provides the abstraction layer for path resolution; this PR extends it.
- Two new skills (`/investigation` and `/vision`, planned in #B and #C) depend on the resolver. They ship after this lands.

## Options Considered

### Option dimension 1 — discovery mechanism

| Option | Pros | Cons |
|--------|------|------|
| **Path-mirroring (chosen)** — drop file at `custom-templates/<path>` matching `templates/<path>` | Zero config; convention-over-configuration; same shape as `handbooks/<dim>/` discovery (#232); no registry to maintain | Adopters who place files at wrong path get silent framework-default fallback (no error) |
| **Frontmatter pointer** — frontmatter in framework templates names override candidates | Explicit; framework can document its own override surface | Requires template-author cooperation; adopters can't add new override paths without framework changes |
| **Config-block table** — `.claude/project-config.json` lists override pairs | Explicit override list; auditable; no "where does this go?" question | Operator maintenance burden; adding a new override = config edit + file write (two steps instead of one) |

Path-mirroring won on operator UX (zero config) and consistency with the existing `handbooks/` discovery convention.

### Option dimension 2 — resolution semantics (override vs additive)

| Option | Pros | Cons |
|--------|------|------|
| **Full replacement (chosen)** — custom file wins; framework default ignored | Predictable; matches "templates are forms" model; adopter owns the whole shape they authored | Adopters lose framework template upgrades silently; must diff manually on `/update` |
| **Additive merge** — framework default's sections + adopter's overrides composed | Framework template improvements flow automatically | Cross-markdown-file section merging is unreliable; section-name conflicts are silent; mental model is "what shape will I actually get?" — worse than override |

Templates are forms (PRD shape, AgDR shape), not content. An adopter authoring `custom-templates/prd.md` deliberately wants their PRD shape used in place of the framework's. Additive composition would be a reliability hazard. The trade-off (lose framework upgrades silently) is documented in `templates/README.md` and `docs/multi-project.md` § "Custom templates".

### Option dimension 3 — where overrides live

| Option | Pros | Cons |
|--------|------|------|
| **Sibling to registry, in private repo for split-portfolio (chosen)** — `<private_repo>/custom-templates/` | Single-fork falls through naturally (registry is in fork → overrides also in fork); split-portfolio keeps overrides private | Helper has to resolve `<private_repo>` from `portfolio_registry`'s parent dir |
| **Always in fork** — `<fork>/custom-templates/` regardless of mode | Simpler resolution (always `<ops_root>/custom-templates/`) | Split-portfolio adopters' overrides leak to public fork — defeats the purpose of split-portfolio mode |
| **In `.claude/custom-templates/`** | Co-locates with other framework-config | `.claude/` is gitignored in some adopter setups; mixes adopter content with framework primitives |

Sibling-to-registry won because it correctly handles both modes — the resolver derives `<private_repo>` from the resolved registry's parent dir, so the same code path works in single-fork (overrides in fork) and split-portfolio (overrides in private sibling).

## Decision

Chosen: **path-mirroring discovery + full-replacement override semantics + sibling-to-registry storage**, exposed via `portfolio_resolve_template <relative_path>` in `_lib-portfolio-paths.sh`.

Resolution order:

1. `<private_repo>/custom-templates/<relative_path>` — adopter override
2. `<ops_root>/templates/<relative_path>` — framework default
3. Empty + nonzero exit — caller decides what to do

Updated consuming skills: `/decide`, `/write-spec`, `/c4`, `/migration`, `/spike`, `/handover`. New skills `/investigation` and `/vision` (planned in #B + #C) consume the resolver from inception.

## Consequences

- Adopters can author company-specific PRD / AgDR / C4 shapes without forking the consuming skill — drop the file at the mirrored path, ship.
- Single-fork adopters with no `custom-templates/` dir see zero behaviour change. Helper falls straight through to framework default.
- Split-portfolio adopters keep customisations in their private repo — never leaks to the public fork.
- Adopters who override a template lose automatic framework template upgrades for that file. Mitigation: `templates/README.md` and `docs/multi-project.md` § "Custom templates" document the diff-on-`/update` discipline; `/update`'s deprecated-config-key advisory pattern (step 8 in the skill) is the model for a future "deprecated template shape" advisory if the failure mode bites adopters.
- Adopters who misplace an override (typo in path, wrong nesting) get silent framework-default fallback. False-positive cost is low (you get the framework version, the skill still works); false-negative cost is also low (the operator notices when the customisation doesn't show up).
- Two new skills (`/investigation`, `/vision`) can ship cleanly on top of this resolver in subsequent PRs.

## Artifacts

- PR for me2resh/apexyard#244
- Helper addition: `.claude/hooks/_lib-portfolio-paths.sh` → `portfolio_resolve_template`
- Tests: `.claude/hooks/tests/test_portfolio_paths.sh` (cases 17-20)
- Docs: `templates/README.md`, `templates/custom-templates.README.example.md`, `docs/multi-project.md` § "Custom templates"

# `/handover` — checklist-first document selection + per-doc template pick

> In the context of `/handover` always generating a fixed set of artefacts (handover assessment + an L2 container stub) with no operator say in what gets produced or which template backs it, facing operators who want only a subset of the docs and who keep adopter template overrides they can't reach from the skill, I decided to add an opt-in **document-selection checklist** (step 5.6) plus a **per-doc template pick** that reuses the existing `portfolio_resolve_template` resolution, defaulting the skill to interactive-with-`--all`-escape, to achieve operator control over the generated set without re-litigating template plumbing, accepting that existing no-flag invocations now see a prompt (mitigated by the `--all` escape that restores the old no-prompt flow byte-for-byte).

## Context

`/handover` adopts an external repo: it clones, reads the surface area, scores harnessability, writes a handover assessment, and stubs an L2 C4 container diagram. The document-generation surface was **fixed** — the operator could not say "skip the container diagram" or "also draft a context diagram", and template-backed docs always rendered from the conventional framework template even when the adopter kept an override at `custom-templates/architecture/`.

Two gaps:

1. **No selection.** A pure-backend handover doesn't need a container diagram; a UI-heavy one might want a journey preview and a DFD. The fixed pipeline forced a one-size output.
2. **No template choice.** The skill already resolves templates via `portfolio_resolve_template` (framework `templates/**` → adopter `custom-templates/**` override), but that resolution was invisible and unprompted — the operator couldn't pick a non-conventional sibling template (e.g. a `c4-container-microservices.md` variant).

The framework already has the UX prior art for an opt-in, per-item interactive flow: `/tickets-batch` and `/plan-initiative` both run a checklist / per-item micro-interview with `all` / `none` / comma-list shorthands.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Leave the fixed pipeline** | Zero new surface; no prompt latency | Operators keep getting docs they don't want and can't reach their template overrides |
| **Always interactive (no `--all`)** | Simplest mental model | Breaks scripted / unattended runs; no way to reproduce today's output non-interactively |
| **`--all` default, `--interactive` opt-in** | Existing muscle memory totally unbroken (no-flag = today's behaviour) | The valuable feature (the checklist) is off by default and gets rediscovered rarely; weaker realisation of the issue's intent |
| **Interactive default, `--all` escape (chosen)** | Realises the issue's recommended shape; the checklist is the thing operators see; `--all` cleanly restores the old flow | No-flag invocations now see one prompt (with a sensible default + the `--all` escape) |
| **A new `/handover-docs` skill** | Clean separation | Splits one logical flow across two skills; the doc set depends on the just-computed assessment, so it belongs inline |

## Decision

Chosen: **interactive-by-default checklist with an `--all` non-interactive escape, plus a per-doc template pick that reuses `portfolio_resolve_template`.**

1. **Checklist after the computed core (step 5.6).** The handover assessment + harnessability score are always written — they are the skill's reason to exist and never appear in the checklist. The checklist gates only the *optional* artefacts (container / context / sequence diagrams, DFD, Feature Inventory, journey, vision). Default-ticked: the L2 container diagram, matching today's default output.

2. **`--all` is the escape, not the default.** Per the issue's "recommend interactive-with-`--all`-escape", interactive is the default. `--all` generates the full default set with conventional templates and no prompt — byte-for-byte the pre-checklist behaviour — so any scripted invocation stays reproducible by adding one flag. `--interactive` names the default for scripts/docs. The behaviour change for existing no-flag callers is a single prompt with a sensible default and an explicit escape; this is the acceptable cost of making the feature discoverable.

3. **Computed/toggle-only vs template-backed is an explicit distinction.** Toggle-only rows (Feature Inventory, journey) have no template to choose — only whether to emit. Template-backed rows (container, context, DFD, vision, sequence) get a second sub-prompt to pick the template.

4. **Per-doc template pick reuses the existing mechanism.** No new resolution code. For each selected template-backed doc, the candidates come from `portfolio_resolve_template <slot>` (framework default + adopter `custom-templates/**` override). The default is always the conventional template — the path the helper would pick unprompted — so empty input keeps `--all` and "default" runs byte-stable. The adopter override is listed only when it exists; an `Other` option globs sibling templates for non-conventional variants.

5. **Hand off, don't reimplement.** Rows owned by dedicated skills (DFD → `/dfd`, Feature Inventory → `/extract-features`, journey → `/journey`, vision → `/tech-vision`) are recorded in the selection and offered as a hand-off after the summary, mirroring step 8's follow-up-skill offer. Only the in-skill C4 stubs (container, context, sequence) are generated inline.

## Consequences

- Existing no-flag `/handover` runs now show a one-line document-selection prompt with the L2 container diagram pre-ticked; pressing enter/`default` reproduces close to today's output. `--all` restores the exact old no-prompt flow.
- Operators can now reach their `custom-templates/**` overrides per doc, and pick non-conventional sibling templates, without touching skill plumbing.
- No new skill, hook, or role — site counts (57 skills / 37 hooks / 20 roles) are unchanged. The change is confined to `.claude/skills/handover/SKILL.md`, the CLAUDE.md one-liner, and this AgDR.
- The bootstrap exemption scope was widened to cover the new `architecture/context.md` and `architecture/sequence-<flow>.md` writes (same `projects/<name>/` class already exempt).
- Re-handover preservation extends to the new stubs: like the container stub, context/sequence are written once and never overwritten.

## Artifacts

- `.claude/skills/handover/SKILL.md` — step 5.6 (checklist + per-doc template pick), step 6.1 (in-skill context/sequence stubs), Usage flags, Output-location + summary updates, Rules 19–20
- `CLAUDE.md` — `/handover` one-line description
- Closes me2resh/apexyard#480

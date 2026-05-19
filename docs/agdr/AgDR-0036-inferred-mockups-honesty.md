# Inferred mockups — ASCII-only, opt-in, with mandatory disclaimer headers

> In the context of `/extract-features`' six-axis discovery already enumerating UI screens (axis 5) for greenfield-rewrite planning, facing the gap that the inventory lists screens by name only with no visual rendering — and the load-bearing risk that any visual rendering of a *model's inference* about a screen will look more authoritative than it should — I decided to ship `--with-mockups` as an **opt-in flag** that emits **ASCII-only** wireframes carrying a **mandatory single-line disclaimer header** (`> AI-inferred sketch — verify before relying on. Source: <path>`) above each box, with a **per-screen-file threshold of 10 screens** to keep the inventory file readable on large apps, to achieve a low-fi "what we must preserve" preview for rewrite teams without anyone confusing the artefact for ground truth, accepting that ASCII is less visually compelling than PNG/SVG, that the disclaimer adds visual noise across the inventory, that inference quality varies by component-library (Tailwind+headless reads cleaner than bespoke CSS), and that operators will occasionally edit the wireframes by hand (markdown is the contract).

## Context

`/extract-features` already runs the discovery — it identifies UI screens, the routes that mount them, the form components they import, and the data-model fields those forms are bound to. The Feature Inventory at `projects/<name>/feature-inventory.md` is the consolidated artefact, but axis 5 today is text-only: every screen is a row in a table with its component name, file path, and any form fields detected. The greenfield-rewrite use case wants a step further — give the team a sketch of each screen so they can negotiate "we keep this, we redesign this, we drop this" against a visual layout, not just names.

Three pressures shape the design:

1. **Inference honesty is load-bearing.** The wireframe is a *guess* the model assembles from static signals (route imports, form-field names, data-model field types). It is not lifted from real DOM. Even with strong signals, the inference can miss conditional UI, hallucinate sections that don't render, or mis-cluster fields. A high-fidelity rendering of a guess is worse than no rendering — the reader assumes accuracy the artefact doesn't have.

2. **File-size on real codebases.** A mid-sized SaaS app has 30-150 features (the inventory matrix target) and often 20-80 UI screens. Inlining every wireframe inside one markdown file produces a file that's painful to scroll and review.

3. **Backward-compat for current adopters.** Adopters who already use `/extract-features` get value from the text-only inventory; the wireframe section is new and not universally wanted. The flag must default OFF.

## Options Considered

### Option A — PNG/SVG mockups rendered from a layout DSL

Have the skill emit a structured layout description (YAML), then render to PNG/SVG via a library. Inline the image references in the inventory.

| Pros | Cons |
|------|------|
| Higher visual fidelity, looks polished in PR review | **Visual fidelity exceeds epistemic confidence** — a polished PNG of a model's guess is the exact failure mode this feature must avoid; readers stop questioning what's inferred |
| PNG embeds cleanly in GitHub markdown | Build step required (rendering library, fonts, deterministic output across machines) |
| | Cannot be edited inline — the operator can't tweak the wireframe in their text editor, so the markdown isn't really the contract |

### Option B — Interactive HTML wireframes (like `/journey`'s output)

Reuse the `/journey` artefact pattern — a single self-contained HTML file with clickable boxes opening modals containing wireframes.

| Pros | Cons |
|------|------|
| Already a sibling pattern in the framework | Different epistemic contract — `/journey` previews flows the operator describes; here the wireframe is the model's inference. Same visual format for two different trust levels is misleading |
| Standalone shareable artefact | Doesn't sit inside the inventory file — readers reviewing the inventory have to context-switch to a browser to see screens |
| | Same visual-fidelity-exceeds-confidence problem as Option A |

### Option C — ASCII boxes inline in the inventory + mandatory disclaimer + opt-in flag (chosen)

ASCII wireframes carry their own epistemic signal — readers see a sketch and treat it as a sketch. The mandatory `> AI-inferred sketch — verify before relying on.` header per wireframe makes the contract impossible to miss. The flag stays opt-in so adopters who don't want mockups see today's inventory unchanged.

| Pros | Cons |
|------|------|
| Visual fidelity matches epistemic confidence — sketch-quality output for sketch-quality inference | Less visually compelling than PNG/SVG — won't win design awards |
| Inline in the inventory (no separate file, no context switch for small apps) — or split per-screen for large apps | ASCII box-drawing is harder to author and validate than a layout DSL |
| Disclaimer header is impossible to miss when reading — even a casual skim of the inventory hits the trust signal | Disclaimer adds visible noise; the same line repeated N times across an inventory feels heavy |
| Markdown IS the contract — operators can edit wireframes inline with no build step | Inference quality varies by component library; bespoke-CSS apps produce thin sketches |
| Backward-compat preserved by the flag — no behaviour change for adopters who don't opt in | Two output modes (inline ≤10 screens, per-screen file >10 screens) — one more rule to remember |

## Decision

Chosen: **Option C** — opt-in `--with-mockups` flag emits ASCII-only wireframes with mandatory disclaimer headers.

Specifically:

1. **ASCII format only, no PNG/SVG/HTML in v1.** The Out-of-scope on the ticket is explicit; if high-fidelity is later wanted, a separate ticket with a different inference strategy.
2. **Mandatory disclaimer header per wireframe** — exact text: `> AI-inferred sketch — verify before relying on. Source: <route or component path>` on its own line above the box. A wireframe without the header is a broken artefact and tests fail on its absence.
3. **Opt-in flag, default off** — running `/extract-features` without the flag produces today's inventory exactly. The flag adds the `## Screens` section; nothing else changes.
4. **File-size handling — threshold of 10 screens**:
   - ≤ 10 screens → emit all wireframes inline in `## Screens` of the inventory.
   - \> 10 screens → emit one file per screen at `<projects_dir>/<name>/screens/<slug>.md`; the inventory's `## Screens` becomes a linked index.

   Why 10? An inventory file at 20+ inlined wireframes (each ~30 lines) is 600+ lines of mostly wireframe content, swamping the per-axis tables. 10 keeps the inventory reviewable in one pass. The threshold is documented; adopters who want a different cut can author a `custom-templates/extract-features.md` override.
5. **Inference rules documented in SKILL.md** — fully enumerated, so the skill's behaviour is reproducible and contestable. Tests in `tests/smoke-mockups.sh` cover the four canonical archetypes (form-heavy, table-heavy, modal, dashboard) and the trust-contract guarantees (every wireframe has the disclaimer; no `## Screens` section without the flag; 80-char width cap inside boxes).

## Consequences

- **Adopters who don't opt in see zero change.** Existing inventories regenerate identically. No migration required.
- **Adopters who opt in get a low-fi sketch per screen alongside the existing text inventory.** Useful for rewrite-planning conversations; not useful as a design deliverable.
- **The disclaimer cannot be stripped without breaking the trust contract.** SKILL.md anti-patterns and tests both call this out; Rex should flag PRs that remove the disclaimer or change its wording.
- **Inference quality varies.** A Tailwind-headless setup reads cleaner than custom CSS; a Next.js app router reads cleaner than a hand-rolled Express+EJS app. The disclaimer covers the bottom-of-the-distribution case.
- **Per-screen files at >10 screens add file-system surface.** The `<projects_dir>/<name>/screens/` dir is a new well-known location; operators have to learn it but it's the right cost on large apps.
- **No PNG/SVG path closes off "polished mockup" use cases.** Adopters who want high-fidelity mockups need a different tool (Figma, FigJam, etc.); the framework is explicit that wireframes here are sketches.

## Artifacts

- Issue: [me2resh/apexyard#290](https://github.com/me2resh/apexyard/issues/290)
- Skill: `.claude/skills/extract-features/SKILL.md` § "`--with-mockups`" and § "4b. Emit ASCII wireframes"
- Tests: `.claude/skills/extract-features/tests/smoke-mockups.sh`
- Sibling discussions: [`AgDR-0016-journey-html-rendering.md`](./AgDR-0016-journey-html-rendering.md) (per-flow HTML; different epistemic contract)

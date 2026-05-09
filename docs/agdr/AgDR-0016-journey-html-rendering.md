---
id: AgDR-0016
timestamp: 2026-05-03T00:00:00Z
agent: claude-opus-4-7
model: claude-opus-4-7
trigger: user-prompt
status: executed
ticket: me2resh/apexyard#179
---

# Hand-rolled SVG + inline JS as the rendering format for `/journey` HTML

> In the context of shipping `/journey` per #179 (a "preview before build" skill that emits a single self-contained HTML file with a clickable boxes-and-arrows graph), facing the choice between Mermaid `flowchart` with `click` directives, hand-rolled SVG + inline JS, and a JS graph library (Cytoscape / D3 / Mermaid loaded as a runtime script), I decided to ship **hand-rolled SVG + inline JS** for v1 — accepting that the layout algorithm starts simple (single-column vertical flowchart) and may need rework when v2 adds swimlanes or denser graphs.

## Context

`/journey` produces a single HTML file that maps a user journey as boxes and arrows. The defining requirement is **single self-contained file**: no CDN, no external CSS or JS, no build step. The reader opens the file in a browser; that's the whole interaction.

The other defining requirement is **clickable boxes that open modal-per-page detail views**. The default view is the whole flow; clicking a box gives the page-level detail (contents, transitions in/out, optional embedded image or wireframe).

Two audiences matter:

1. **Operators inside ApexYard** — they invoke the skill, review the HTML in the browser, and commit both the YAML source-of-truth and the HTML build artifact. They have `gh`, `git`, a shell, and a modern browser. They don't have or want a Node toolchain just to render a journey preview.

2. **Stakeholders outside ApexYard** — PMs, designers, the CEO. They receive the HTML as an attachment (or a GitHub Pages link) and open it in Chrome / Safari / Firefox. Anything that requires "let me set up a dev server first" is dead on arrival for this audience.

Adjacent precedent: `/c4` ships Mermaid markdown that GitHub renders inline. That pattern works because GitHub natively renders Mermaid in `.md` files — no JS needed at view time. The journey HTML is **not** a markdown file, so that mechanism doesn't apply.

## Options Considered

| Option | Pros | Cons |
|--------|------|------|
| **Mermaid `flowchart` with `click` directives, loaded inline as a `<script>` blob** | Familiar DSL — same library `/c4` uses elsewhere. Mermaid auto-layouts the graph. Modest LOC in the skill. | Mermaid's `click` directive can call a JS function but the modal HTML is still hand-written. Renders client-side via a ~700KB bundled JS blob inlined into every HTML output — bloats every committed HTML file. The skill output ends up being mostly Mermaid runtime. Modal interactivity is a custom layer regardless. |
| **Hand-rolled SVG + inline JS** | Zero runtime dependencies. Full control over click behaviour, modal open/close, focus management, keyboard handling. ~150 lines of JS + ~80 lines of CSS = a tight, auditable artifact. Output file size is a few KB instead of a few hundred. | Layout algorithm is hand-rolled too — v1 ships a simple BFS-by-row vertical flowchart; complex graphs (many parallel paths, dense back-edges) will look messy. v2 may need a real layout engine when swimlanes / graph mode arrive. |
| **JS graph library inlined (Cytoscape / D3-graphviz)** | Sophisticated layouts (force-directed, hierarchical, swimlanes). Battle-tested. | Cytoscape minified is ~400KB; D3 + graphviz-wasm is multiple MB. Inlining either explodes the HTML file size beyond what's reasonable to commit. Modal interactivity is still a custom layer on top. The "single file" constraint becomes "single huge file". |
| **Mermaid auto-rendered by GitHub (markdown, not HTML)** | Zero JS, GitHub renders inline, same as `/c4`. | Defeats the requirement: the artifact must be a **standalone HTML file** that opens in any browser, not a markdown file that depends on GitHub's renderer. Also: Mermaid's `click` directive only works in HTML context, not in GitHub-rendered markdown — clicking a box in a GitHub-rendered Mermaid diagram does nothing. |

### Decision dimensions weighted

| Dimension | Weight | Mermaid inline | Hand-rolled SVG | JS lib inline | GH-rendered MD |
|-----------|--------|----------------|-----------------|---------------|----------------|
| **Single self-contained file** (no CDN, no fetch) | Critical | ~ (inlined runtime works but bloats) | ✅ | ~ (file gets huge) | ❌ (depends on GH renderer) |
| **Click → modal open is first-class** | Critical | ~ (click directive limited; modals hand-written anyway) | ✅ | ~ (still hand-written modals) | ❌ (no click in GH-rendered MD) |
| **File size stays committable** (< 50KB typical, < 200KB worst-case) | High | ❌ (~700KB Mermaid runtime) | ✅ (3-15KB typical) | ❌ (multi-MB) | ✅ |
| **Layout quality on small graphs (≤ 12 nodes)** | High | ✅ | ~ (simple but readable) | ✅ | ✅ |
| **Layout quality on dense graphs (cycles, many edges)** | Low (deferred — v1 caps at 12 pages, 30 transitions) | ✅ | ❌ | ✅ | ✅ |
| **Auditable / patchable by operators** | Medium | ❌ (Mermaid internals are opaque) | ✅ (it's a few hundred lines of vanilla DOM code) | ❌ (library internals) | n/a |
| **No build / runtime dependency** | High | ✅ | ✅ | ✅ | ✅ |

Hand-rolled SVG wins on three of the four critical / high dimensions. It loses on dense-graph layout quality, which is a v2 concern explicitly capped out of v1 (max 12 pages, 30 transitions).

The Mermaid `click` directive deserves a specific note: it exists, but it's intended for opening external URLs or calling globally-scoped JS functions. Wiring it to per-page modal HTML still requires writing the modal HTML and a click handler by hand — the "Mermaid does it for us" assumption doesn't survive contact with the modal-per-page requirement.

## Decision

Chosen: **hand-rolled SVG + inline JS for v1**, with a simple BFS-by-row vertical-flowchart layout. The skill output is a single `.html` file with all CSS and JS inline; opens in any browser; total size 3-15KB for typical (3-8 page) journeys.

Concretely:

- v1 layout: identify entry page, BFS from there, place pages in rows by BFS depth, distribute evenly within a row. Cycles → break for layout, render the back-edge as a curved arrow.
- v1 caps: 12 pages max, 30 transitions max. Above that, ask the operator to split into multiple journeys.
- Persona colour-coding via `data-persona` attribute + CSS attribute selector — no JS state for personas.
- Modal interactivity: vanilla DOM (`addEventListener`, `hidden` attribute, focus management). ~50 lines of JS.
- Total CSS budget: ~100 lines. Total JS budget: ~50 lines. Total HTML file size for a 6-page journey: ~10KB.

## Consequences

### Immediate

- The skill ships with a hand-rolled layout algorithm and renderer. Operators reading the generated HTML see a few hundred lines of vanilla DOM code; auditable, patchable, no library to learn.
- File sizes stay small enough to commit comfortably (single-digit KB for typical journeys). PR diffs of HTML changes remain readable.
- Operators with no JS toolchain can edit the YAML and `--update` to regenerate; no `npm install` required at any point.

### Deferred

- **Swimlane layout for multi-persona flows** (v2). The `personas:` YAML field is parsed and colour-coded today, but lanes-per-persona layout is deferred until a real journey needs it.
- **Denser graph mode** (v2 / v3). When a journey legitimately has > 12 pages or > 30 transitions, either split it (v1 advice) or invest in a real layout engine. Cytoscape and D3-graphviz are both candidates; the decision can be revisited when a concrete need lands.
- **Auto-layout escape hatch via Mermaid** for users who prefer Mermaid's auto-layout over the hand-rolled one. Adding it means a second renderer mode behind a flag; not free, not v1.

### Costs if we're wrong

Modest. If the hand-rolled layout proves too brittle, swapping in a JS graph library is a renderer-only change — the YAML schema stays stable, the modal layer stays the same. The cost is one PR's worth of work, plus a one-time reckoning with file-size growth.

The migration risk is low because the YAML is the source of truth. Existing journey YAML files render correctly under any future renderer; the HTML build artifact is regenerable.

### Costs if we're right but wait

Higher. Without a journey-preview skill, PMs and designers continue building isolated mockups (one per page) with no flow visualisation, and logic gaps surface only at first implementation review. Shipping the hand-rolled v1 now closes that gap; the swimlane / dense-graph polish can come later when actual usage data tells us which polish matters.

## Artifacts

- Skill: `.claude/skills/journey/SKILL.md`
- Documentation: `workflows/sdlc.md` (linked between Phase 1 Planning and Phase 2 Technical Design)
- Ticket: [me2resh/apexyard#179](https://github.com/me2resh/apexyard/issues/179)
- PR: (filled at merge time)

---
name: journey
description: Generate a single self-contained HTML user-journey map — boxes-and-arrows graph with a clickable modal per page. Sits between PRD and tech-design as a "preview before build" artifact, surfacing flow-level logic gaps before any implementation begins.
disable-model-invocation: false
argument-hint: "[<feature-slug>] [--from-prd <path>] [--from-yaml <path>] [--update] [--wireframe]"
allowed-tools: Bash, Read, Grep, Glob, Write
effort: medium
---

# /journey — User-Journey HTML with Modal-Per-Page Design Preview

Generate a single self-contained HTML file at `projects/<name>/journeys/<feature-slug>.html` mapping the user journey as clickable boxes (each opening a modal with the page's content). Companion skill to `/c4` (architecture preview) and `/threat-model` (security preview) — closes the gap on **flow-level** preview before any implementation.

## When to use

| Trigger | Use `/journey`? |
|---------|----------------|
| PRD approved, about to start tech design | Yes — visualises the flow the PRD describes, surfaces missing states |
| Stakeholder review of a new feature flow | Yes — single-file HTML, opens in any browser, shareable as an attachment |
| Quick "what does this look like as a flow?" sketch | Yes — conversational mode is 5 questions |
| Per-page visual design (high-fidelity mockups) | No — `/journey` is flow-first; per-page mockups are designer territory |
| Architecture diagrams | No — use `/c4` for L1/L2 architecture |
| Production deliverable HTML | No — the artifact is a draft preview, not production code |

## Activated role

When `/journey` runs, activate the **[UX Designer](../../../roles/design/ux-designer.md)** role — they own user flows and information architecture. For PRD parsing in mode (a), the **[Product Manager](../../../roles/product/product-manager.md)** is the supporting role (they wrote the PRD). See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir}` keys in `.claude/project-config.json`. Don't hardcode literal `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/journey                                        # conversational — asks for project, feature, pages, transitions
/journey checkout-v2                            # conversational, feature pre-named
/journey checkout-v2 --from-prd projects/example-app/prds/checkout.md
/journey checkout-v2 --from-yaml projects/example-app/journeys/checkout-v2.yaml
/journey checkout-v2 --update                   # regenerate HTML from existing YAML
/journey checkout-v2 --wireframe                # ask for inline HTML wireframe sketches in modals (v1, optional)
```

Argument shape:

| Form | Behaviour |
|------|-----------|
| No args | Conversational mode; ask for the project + feature first |
| `<feature-slug>` only | Conversational mode for that feature (slug becomes the filename) |
| `--from-prd <path>` | Parse pages + transitions from a PRD file |
| `--from-yaml <path>` | Load structured journey data from a YAML file |
| `--update` | Re-render the HTML from `<feature-slug>.yaml` without re-asking |
| `--wireframe` | (Default OFF) ask the agent to sketch HTML wireframes inline in each page's modal |

`--from-prd` and `--from-yaml` are mutually exclusive. `--update` is mutually exclusive with both — it always reads from the existing YAML.

## Output location

Files are written under the **per-project docs dir** (resolved via `portfolio_projects_dir`):

| File | Path | Purpose |
|------|------|---------|
| YAML source-of-truth | `<projects_dir>/<name>/journeys/<feature-slug>.yaml` | Editable, diff-reviewable, regenerable input |
| HTML build artifact | `<projects_dir>/<name>/journeys/<feature-slug>.html` | Single self-contained file — no external deps |

Both are committed. The YAML so reviewers can diff flow changes across PRs; the HTML so reviewers don't need to re-render to see it.

## Process

### 1. Resolve the target project

Same pattern as `/feature`, `/bug`, `/c4`:

- If invoked from `workspace/<name>/` → `<name>` is the project.
- If invoked from the ops-fork root → ask which project this journey is for (list registered projects from `apexyard.projects.yaml`).
- If exactly one project is registered → use it without asking.
- If a `<feature-slug>` argument was passed and a journey already exists at `<projects_dir>/<name>/journeys/<feature-slug>.yaml`, infer the project from that path.

### 2. Resolve the feature slug

The slug becomes the filename (without extension). Prefer kebab-case, max 40 chars.

- If `<feature-slug>` was passed as the first positional arg → use it.
- If `--from-prd <path>` and the PRD has a clear title → derive a slug from the title.
- Otherwise → ask: "What's the feature name? (used as the filename)".

### 3. Source the journey data

Three input modes — pick whichever the operator's flags imply, or ask if ambiguous.

#### Mode (a) — From a PRD

Triggered by `--from-prd <path>` (relative to the ops-fork root or absolute).

Read the PRD. Look for these structural cues to extract pages and transitions:

| Cue | Inferred |
|-----|----------|
| `## User Flow` / `## User Journey` / `## Flow` heading | Section to parse for pages |
| Numbered steps under "Flow" / "Journey" / "Steps" | Each step is a page candidate |
| `- User clicks X → goes to Y` patterns | A transition from current page to Y |
| `## Pages` / `## Screens` heading | Each subheading is a page |
| `## Acceptance Criteria` with Given/When/Then | Pre-conditions / post-conditions = transitions |
| Mermaid `graph` or `flowchart` blocks | Direct edge list |

If the PRD is too prose-heavy to parse mechanically, fall back to mode (b) but pre-fill the conversation with the PRD's title, problem statement, and any explicit flow notes.

#### Mode (b) — Conversational

Default mode when no `--from-*` flag is given. A 5-question micro-interview:

1. **Pages** — "What pages / screens / states are in this flow? (one per line, name + 1-line description)"
2. **Entry point** — "Which page does the user land on first?"
3. **Transitions** — "What are the transitions? Format: `<from> -> <to> on <trigger>` (e.g. `Login -> Dashboard on submit`). One per line."
4. **Personas** — "Are there multiple personas (e.g. user / admin / system)? Optional — leave blank for single-persona."
5. **Notes** — "Any global notes about the flow? (e.g. 'all pages require auth except Login')"

Capture answers verbatim into the YAML structure below.

#### Mode (c) — From YAML

Triggered by `--from-yaml <path>` or `--update` (which uses the canonical path `<projects_dir>/<name>/journeys/<feature-slug>.yaml`).

Load the YAML as-is. Validate it has the required top-level keys; if not, surface what's missing and stop.

### 4. Validate the journey graph

Before writing files, sanity-check:

- **Every page is reachable.** Walk transitions from the entry page; flag any unreachable page.
- **Every `to:` and `from:` references a page that exists.** Typos here are the most common mistake.
- **Hard cap at 12 pages.** A v1 journey with more than 12 pages is almost certainly two journeys; ask the operator to split.
- **Hard cap at 30 transitions.** Same reasoning — too dense to render readably.

If validation fails, list the issues and ask the operator how to fix (the conversation is cheap; rendering an unreadable graph is expensive).

### 5. Persist the YAML

Write `<projects_dir>/<name>/journeys/<feature-slug>.yaml` with this shape:

```yaml
version: 1
feature: <feature-slug>
project: <name>
title: <human-readable title>
description: <one-sentence description>
generated_at: <ISO-8601>
generated_by: /journey

# Optional persona dimension. When absent, single-persona flow.
personas: []  # or: [user, admin, system]

# Pages = nodes in the graph.
pages:
  - id: <kebab-case id>
    title: <Display Name>
    persona: <persona-id, optional>
    description: <one-line summary>
    contents:
      - <bullet describing what's on the page>
      - <another bullet>
    success_state: <what "success" looks like on this page, optional>
    error_state: <what error/edge/empty looks like, optional>
    image: <relative path or URL to an image, optional>
    wireframe_html: <inline HTML when --wireframe is on, optional>

# Transitions = directed edges.
transitions:
  - from: <page-id>
    to: <page-id>
    trigger: <user-readable description, e.g. "submits form">

# Entry point: the first page the user lands on.
entry: <page-id>

# Optional notes shown on the journey overview.
notes: |
  Multi-line notes about the flow, prerequisites, etc.
```

Write the file. If it already exists and `--update` was NOT passed, ask before overwriting (the YAML may have hand edits the operator wants to keep).

### 6. Render the HTML

Generate `<projects_dir>/<name>/journeys/<feature-slug>.html` — a **single self-contained file** with all CSS and JS inline. No `<script src=…>`, no `<link rel="stylesheet" href=…>`, no CDN references.

The HTML structure:

```
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title} — User Journey</title>
  <style>/* inline CSS — see § "Inline CSS" below */</style>
</head>
<body>
  <header>
    <div class="meta">
      <div class="project">{project}</div>
      <h1>{title}</h1>
      <div class="description">{description}</div>
      <div class="disclaimer">DRAFT — preview before implementation. Not a production deliverable.</div>
      <div class="timestamp">Generated {generated_at}</div>
    </div>
  </header>

  <main>
    <section class="graph">
      <svg viewBox="0 0 {width} {height}" role="img" aria-label="User journey graph">
        <!-- Boxes (one <g> per page, with id="page-{page.id}") -->
        <!-- Arrows (one <path> per transition) -->
        <!-- Click handlers attach to each <g> via inline JS below -->
      </svg>
    </section>

    {modals}  <!-- One <div class="modal" id="modal-{page.id}"> per page -->
  </main>

  <footer>
    <div>Source: <code>{yaml_path}</code></div>
    <div>Regenerate: <code>/journey {feature-slug} --update</code></div>
  </footer>

  <script>/* inline JS — see § "Inline JS" below */</script>
</body>
</html>
```

#### Layout algorithm (v1: vertical flowchart)

Compute box positions before emitting SVG:

1. Identify the **entry page** (`entry:` field).
2. Topologically sort pages by BFS distance from entry. Pages at the same BFS depth are in the same row.
3. Within a row, distribute boxes evenly across the canvas width.
4. Box dimensions: width 220px, height 80px. Row spacing: 140px. Column spacing: 40px (between boxes in the same row).
5. Cycles → break the cycle at the longest back-edge for layout purposes; the back-edge is still drawn as an arrow with a curved path.
6. Total canvas: `width = max(rowWidths)`, `height = (numRows - 1) * rowSpacing + boxHeight + 80px` (top + bottom padding).

For v1, this layout is intentionally simple. A page with 8 outgoing transitions will look messy — that's an acceptable v1 trade-off; complex graphs are a v2 concern.

#### Boxes

Each page renders as an SVG `<g>` with a `<rect>` and centered `<text>`:

```svg
<g class="page-box" id="page-{id}" data-page-id="{id}" tabindex="0" role="button" aria-label="Open details for {title}">
  <rect x="..." y="..." width="220" height="80" rx="8" />
  <text x="..." y="..." text-anchor="middle" dominant-baseline="middle">
    <tspan class="page-title" x="...">{title}</tspan>
    <tspan class="page-persona" x="..." dy="18">{persona}</tspan>  <!-- if persona set -->
  </text>
</g>
```

Persona styling: if the page has a `persona` field, give the `<g>` a `data-persona="{persona}"` attribute and use CSS to colour-code (one colour per distinct persona, picked deterministically from a small palette). Without persona, all boxes use the default neutral fill.

#### Arrows

Each transition renders as an SVG `<path>` with a `<text>` label centered along the path:

```svg
<defs>
  <marker id="arrowhead" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto">
    <path d="M0,0 L10,5 L0,10 z"/>
  </marker>
</defs>

<path class="transition-arrow"
      d="M{x1},{y1} C{cx1},{cy1} {cx2},{cy2} {x2},{y2}"
      marker-end="url(#arrowhead)" />
<text class="transition-label" x="..." y="...">{trigger}</text>
```

For straight downward arrows (parent row → next row), use a simple cubic curve with control points at the midpoint. For back-edges (cycles), use a wide curve that arcs to the side.

#### Modals

One modal per page, hidden by default:

```html
<div class="modal" id="modal-{id}" role="dialog" aria-modal="true" aria-labelledby="modal-title-{id}" hidden>
  <div class="modal-backdrop" data-close-modal="{id}"></div>
  <div class="modal-content">
    <header>
      <h2 id="modal-title-{id}">{title}</h2>
      {persona-pill if persona set}
      <button class="modal-close" data-close-modal="{id}" aria-label="Close">×</button>
    </header>
    <section class="modal-description">{description}</section>
    <section class="modal-contents">
      <h3>Page contents</h3>
      <ul>
        {one <li> per contents bullet}
      </ul>
    </section>
    {modal-success-state section if set}
    {modal-error-state section if set}
    <section class="modal-transitions-in">
      <h3>Transitions in</h3>
      <ul>
        {one <li> per incoming transition: "from {other-page-title} on {trigger}"}
      </ul>
    </section>
    <section class="modal-transitions-out">
      <h3>Transitions out</h3>
      <ul>
        {one <li> per outgoing transition: "to {other-page-title} on {trigger}"}
      </ul>
    </section>
    {modal-image section if image set}
    {modal-wireframe section if wireframe_html set — inline HTML wrapped in a sandboxed wireframe container}
  </div>
</div>
```

#### Inline CSS (sketch — keep under ~100 lines)

```css
* { box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
       margin: 0; color: #1f2937; background: #f9fafb; }
header { padding: 24px 32px; background: #fff; border-bottom: 1px solid #e5e7eb; }
header h1 { margin: 0 0 4px; font-size: 1.5rem; }
header .project { font-size: 0.85rem; color: #6b7280; text-transform: uppercase; letter-spacing: 0.04em; }
header .description { color: #4b5563; margin-top: 6px; }
header .disclaimer { display: inline-block; margin-top: 12px; padding: 4px 10px;
                     background: #fef3c7; color: #92400e; font-size: 0.8rem; border-radius: 4px; font-weight: 600; }
header .timestamp { font-size: 0.75rem; color: #9ca3af; margin-top: 8px; }
main { padding: 32px; }
section.graph { display: flex; justify-content: center; }
svg { max-width: 100%; height: auto; }
.page-box rect { fill: #fff; stroke: #6366f1; stroke-width: 2; cursor: pointer;
                 transition: fill 0.15s, stroke 0.15s; }
.page-box:hover rect, .page-box:focus rect { fill: #eef2ff; stroke: #4338ca; }
.page-box text { font-size: 14px; pointer-events: none; }
.page-title { font-weight: 600; }
.page-persona { font-size: 11px; fill: #6b7280; }
.transition-arrow { fill: none; stroke: #9ca3af; stroke-width: 1.5; }
.transition-label { font-size: 11px; fill: #4b5563; pointer-events: none; }
.modal[hidden] { display: none; }
.modal { position: fixed; inset: 0; z-index: 1000; }
.modal-backdrop { position: absolute; inset: 0; background: rgba(17, 24, 39, 0.5); }
.modal-content { position: relative; max-width: 640px; margin: 5vh auto; max-height: 90vh;
                 overflow-y: auto; background: #fff; border-radius: 8px; padding: 24px;
                 box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2); }
.modal-content header { display: flex; align-items: center; gap: 12px; padding: 0 0 16px;
                        border-bottom: 1px solid #e5e7eb; background: transparent; }
.modal-content header h2 { margin: 0; font-size: 1.25rem; flex: 1; }
.modal-close { background: none; border: 0; font-size: 1.5rem; cursor: pointer; color: #6b7280; }
.modal-close:hover { color: #1f2937; }
.modal-content section { margin-top: 16px; }
.modal-content h3 { font-size: 0.9rem; text-transform: uppercase; letter-spacing: 0.05em;
                    color: #6b7280; margin: 0 0 8px; }
.modal-content ul { padding-left: 20px; margin: 0; }
.persona-pill { display: inline-block; padding: 2px 8px; font-size: 0.75rem;
                background: #eef2ff; color: #4338ca; border-radius: 999px; }
footer { padding: 24px 32px; font-size: 0.8rem; color: #6b7280;
         border-top: 1px solid #e5e7eb; background: #fff; }
footer code { background: #f3f4f6; padding: 2px 6px; border-radius: 3px; font-size: 0.85em; }
```

Persona colour rotation (only when `personas` is non-empty): cycle through `#6366f1`, `#10b981`, `#f59e0b`, `#ec4899`, `#8b5cf6` — apply via attribute selector `.page-box[data-persona="X"] rect { stroke: ...; }`.

#### Inline JS (sketch — keep under ~50 lines)

```js
(function () {
  const pages = document.querySelectorAll('.page-box');
  const modals = document.querySelectorAll('.modal');

  function openModal(id) {
    const m = document.getElementById('modal-' + id);
    if (!m) return;
    m.hidden = false;
    document.body.style.overflow = 'hidden';
    const closeBtn = m.querySelector('.modal-close');
    if (closeBtn) closeBtn.focus();
  }

  function closeModal(id) {
    const m = document.getElementById('modal-' + id);
    if (!m) return;
    m.hidden = true;
    document.body.style.overflow = '';
    const trigger = document.getElementById('page-' + id);
    if (trigger) trigger.focus();
  }

  pages.forEach((p) => {
    const id = p.dataset.pageId;
    p.addEventListener('click', () => openModal(id));
    p.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openModal(id); }
    });
  });

  document.querySelectorAll('[data-close-modal]').forEach((el) => {
    el.addEventListener('click', () => closeModal(el.dataset.closeModal));
  });

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      modals.forEach((m) => { if (!m.hidden) closeModal(m.id.replace(/^modal-/, '')); });
    }
  });
})();
```

### 7. Confirm to the user

```
✓ <project>: Journey written

  YAML: <projects_dir>/<name>/journeys/<feature-slug>.yaml  (source of truth)
  HTML: <projects_dir>/<name>/journeys/<feature-slug>.html  (preview)

  Pages: <N>      Transitions: <M>      Personas: <P or "single">

Open the HTML directly in a browser. To edit, change the YAML and run:
  /journey <feature-slug> --update
```

If this was a `--from-prd` run, append a one-line tip:

```
  Source PRD: <path>
```

## Rules

1. **Single self-contained HTML** — no external CSS, JS, or font references. Everything inline. The whole point is "open the file, see the journey" — a fetch failure on a CDN should never break the artifact.
2. **YAML is the source of truth** — never hand-edit the HTML. `--update` regenerates from YAML; the HTML is replaced entirely on each run.
3. **Hard cap at 12 pages, 30 transitions** — bigger journeys are usually two journeys. Ask the operator to split.
4. **Modal-per-page is mandatory** — even if the modal only has a one-line description. The interaction model is "click a box, see the detail"; without modals the artifact is just an unstyled flowchart.
5. **Don't fabricate page contents** — in mode (b), if the operator didn't list contents for a page, the modal shows the description only. Don't invent bullets the operator didn't specify.
6. **`--wireframe` is opt-in (v1)** — default to prose-only modals. Wireframe sketches are bounded by what the agent can produce in plain HTML; document this in the modal so reviewers don't mistake a sketch for a real design.
7. **Disclaimer banner is mandatory** — every generated HTML carries the "DRAFT — preview before implementation" line. The artifact is a flow-mapping tool, not a design deliverable.
8. **No JS frameworks, no build step** — vanilla DOM API only. The reader must be able to open the HTML in any browser without a server.

## Out of scope (v1)

- **Swimlane layout** — single-persona flowchart only. Multi-persona swimlanes are a v2 question (gated on the `personas:` field).
- **Live preview / hot-reload** — `--update` is the only regen path.
- **Cross-project journeys** — one project per invocation. Portfolio-spanning flows (e.g. shared auth across projects) are a v2 concern.
- **Real designtool integration** (Figma API, Sketch export) — v1 takes paths or URLs only; deeper integration is v3.
- **A11y / responsive testing of the generated HTML** — the journey is a preview artifact, not a production deliverable; basic keyboard + ARIA is provided but not exhaustively tested.
- **Image embedding via base64** — v1 references images by relative path or URL only. Base64 inflates the file size; if the operator wants a self-contained build, they reference images on the same disk and copy both files together.

## Relationship to other skills

| Skill | Relationship |
|-------|-------------|
| `/write-spec` | Produces the PRD that feeds `/journey --from-prd`. Sequential pair. |
| `/c4` | Sibling preview-before-build skill. `/c4` shows architecture; `/journey` shows user flow. |
| `/threat-model` | Sibling skill. `/threat-model` shows attack surface; `/journey` shows user flow. |
| `/feature` / `/bug` / `/task` | Tracker creation. `/journey` is sometimes attached to a feature ticket as a flow preview. |

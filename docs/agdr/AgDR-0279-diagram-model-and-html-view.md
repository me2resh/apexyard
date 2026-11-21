# AgDR-0279: Diagram model and HTML view

> Facing static, unstyled Mermaid diagrams that a reader cannot explore, the owner chose one typed diagram model that generates both the Mermaid block and a self-contained HTML view, built by a shared Python generator, accepting Python 3.9+ for `--html` and a simple layered layout.

## Context

This record is step 0 of [#1919](https://github.com/me2resh/apexyard/issues/1919).
`/c4`, `/dfd` and `/feature-diagram` write Mermaid text into markdown.
GitHub draws it with its default theme and automatic layout, and a reader cannot click, trace or follow a source link.
Today the three skills share no structure:

- `/c4` has no generator. The agent writes the Mermaid from the confirmed plan.
- `/dfd` has a JSON model for its threat-model export, but its Mermaid generator ignores that model.
- `/feature-diagram` has a Bash 3.2 generator. Its edges connect its four layers, not single nodes.
- `/journey` already writes one self-contained HTML file, written by the agent by hand.

The framework repository has no design tokens. Its one brand value is the badge blue `#2F6DF6` (AgDR-0090).

Owner decisions of 2026-10-29: three step PRs on #1919, the HTML is committed next to the markdown, the trace follows arrow direction for every diagram type, and the view uses a new `--ay-*` token set.
A later owner decision of 2026-10-29: v1 does not support diagrams that span more than one repository.

## Relation to earlier decisions

This record amends one earlier decision and builds an option that another earlier decision deferred. It leaves three others unchanged.

- [AgDR-0003](AgDR-0003-mermaid-c4-for-diagrams.md) chose Mermaid C4 in markdown. It weighted "single-source" as High and rejected a committed rendered file next to its source.
  - This record amends that single-source rule for `--html` runs only.
  - With `--html`, the model `<stem>.diagram.json` becomes the source of truth. The Mermaid block is generated from the model. The HTML is a second generated file, and both are committed.
  - The #1919 text says "Keep Mermaid as the source of truth". For `--html` runs, the model replaces Mermaid as the source. The Mermaid block stays the view that GitHub renders and that reviewers read.
  - `diagram.py check` keeps the model, the Mermaid block and the HTML equal.
  - Runs without `--html` do not change. For them, the markdown stays the single source, as AgDR-0003 decided.
- [AgDR-0016](AgDR-0016-journey-html-rendering.md) chose hand-written SVG and inline JS for the `/journey` HTML, with a committed YAML source and a committed HTML file.
  - It is the precedent for one self-contained HTML file with no runtime library, and for a committed HTML file next to its source.
  - `/journey` does not change. Moving `/journey` onto the shared template is out of scope.
- [AgDR-0026](AgDR-0026-dfd-skill-as-source-of-truth.md) made `/dfd` the single producer of the DFD. Its Option D (one intermediate model, many renderers) was deferred as premature for v1.
  - This record builds the option that AgDR-0026 deferred. The `apexyard.diagram/v1` model is that intermediate model, for `--html` runs of `/c4`, `/dfd` and `/feature-diagram`.
  - AgDR-0026 kept the generators as pure functions over one in-memory model so that Option D could come later. The `from-dfd` adapter reads that same model.
  - The `/dfd` heading contract with `/threat-model` does not change. The Threat Dragon export does not change.
  - The `/dfd --scope-all` multi-repo diagram from AgDR-0026 has no `--html` support in v1.
- [AgDR-0035](AgDR-0035-per-feature-diagrams.md) defined the `/feature-diagram` shape: four layer subgraphs, the edge inference rules and the re-run rules.
  - The four layers, the edge rules, the node id form and the re-run rules do not change.
  - The model represents a layer-level edge with a group as an edge end, for the `feature` type only.
- [AgDR-0248](AgDR-0248-process-bpmn-grid-layout.md) chose a standard-library Python 3.9 grid layout for `/process`.
  - It is the precedent for Python 3.9 or later as a skill prerequisite, and for a layout with longest-path columns and back edges removed.
  - This record uses the same runtime floor and the same method in its own code. `/process` does not change.

## Options Considered

### 1. Source of truth

| Option | Pros | Cons |
|--------|------|------|
| **A. One typed model (`apexyard.diagram/v1`, `<stem>.diagram.json`) generates both outputs** | Mermaid and HTML cannot disagree. One validator covers both. Source links and groups have a defined shape | Each skill needs an adapter to the model. A new file appears next to the markdown |
| B. Parse the Mermaid text and build the HTML from it | No new file. Works on old diagrams | Mermaid has no fields for source links, layers or kinds. The C4 grammar is beta. A parser must follow each grammar change |
| C. Hand-written HTML per skill, as `/journey` does | No shared code | Three copies drift. Nothing checks that the HTML matches the Mermaid |

### 2. Generator and layout

| Option | Pros | Cons |
|--------|------|------|
| **A. Python 3.9+ standard library in `.claude/skills/_lib-diagram/`, layout computed in Python** | No dependency. Deterministic output, so the committed HTML diffs cleanly. `/process` already needs Python 3.9+ | Python is required for `--html`. The layered layout reduces crossings but does not minimise them |
| B. Layout computed by JavaScript in the browser | No Python | The positions change between viewers and are not testable in CI without a browser. The HTML diff shows nothing useful |
| C. Bundle a layout library in the template | Better layouts for dense graphs | A large inline payload in every file, a licence to track, and code that we do not own in a file that we commit and ship |

### 3. The HTML file

| Option | Pros | Cons |
|--------|------|------|
| **A. One template with all code inline, a hash-based CSP with `default-src 'none'`, and DOM building with `textContent` only** | Works offline. The browser blocks any network call. Text from a scanned repository cannot run as script | The template has to stay small and readable. No external fonts |
| B. A page that loads its script from a CDN | Smaller file | Breaks offline, adds a third-party request, and widens the injection surface |

## Decision

Chosen: **1A, 2A and 3A**, because a single model is the only option that keeps the Mermaid and the HTML in step and gives each node a checked source link. Python layout makes the committed file deterministic and testable in CI. An inline template with a strict CSP keeps the view offline and safe for text that comes from scanned code.

The details:

- The model holds `diagram`, `generated`, `repo` (name, web URL, commit), `groups`, `nodes` (with `sources` of path and line) and `edges`. Each diagram type has a fixed set of node and group kinds.
- `diagram.py validate` runs before either output is written. It fails on any of these faults:
  - an edge to an unknown node
  - a source path that is not in the pinned commit, or a line past the end of the file
  - a commit that is not 40 hex characters or is not in the clone
  - a `null` commit while a node or edge has sources (a `null` commit with no sources is valid)
  - a web URL that is not `https://`, or that holds user information, a query or a fragment
- The generator gets the web URL from the `origin` remote. It converts an SSH remote to `https://<host>/<owner>/<repo>` and removes user information and the `.git` suffix.
- An automatic edge id is `e_` plus the first 10 hex characters of SHA-256 over `from`, `to` and `label`, with `_<n>` added for a duplicate.
- The model hash is SHA-256 over the canonical, normalised model without the `generated` block (sorted keys, compact separators, ASCII). A comment above the Mermaid block holds the model path and the hash. The HTML holds the same hash. `diagram.py check` regenerates the block, compares the hash in the markdown and in the HTML, and fails on drift.
- The model goes into the HTML as a non-executed `application/json` block. The generator writes each `<`, `>` and `&` in the serialised JSON as the JSON Unicode escapes `\u003c`, `\u003e` and `\u0026` (a backslash, `u` and four hex digits). The data block therefore contains no raw `<`.
- The CSP meta tag is the first child of `<head>`. The generator fills all placeholders in one pass over the template. No model text goes into the markup outside the data block: the script sets `document.title` from the data block.
- Source links use the GitHub and GitLab URL forms. Other hosts show plain text.
- Without `--html`, no model is written, no Python runs, and the skill output does not change.

## Consequences

- A new shared library under `.claude/skills/_lib-diagram/`: the model schema, the validator, the Mermaid emitter, the layout step and `view.html`.
- `/c4`, `/dfd` and `/feature-diagram` each gain `--html` in PR 3. `/dfd` and `/feature-diagram` each gain a model adapter (`from-dfd` and `from-tsv`). `/c4` has no adapter script: the agent writes the model from the proposal that the user confirmed. `/c4 --html` with `--dsl` is an error.
- The v1 model holds one repository. `/dfd --html --scope-all` is an error. A later ticket needs a v2 schema to support it.
- `/feature-diagram` keeps its layer-level edges: for that type only, a group can be an edge end.
- Python 3.9+ becomes a requirement for `--html` only. The skill checks it and stops with a clear message when it is missing.
- The layered layout is readable up to about 80 nodes and 200 edges. The validator refuses more than 300 nodes or 1,000 edges.
- A hand edit to the Mermaid after an `--html` run makes `diagram.py check` fail. The fix is to edit the model and generate again.
- CI runs the validator tests, a self-contained check on the HTML (no network URL, CSP present), and the trace and path logic under `node` when `CI=true`.
- PR 2 (template and interaction) needs a design review and a security review.

### Out of scope for v1

- Diagrams that span more than one repository, for example `/dfd --scope-all`.
- Editing a diagram in the browser, hosted sharing, BPMN, C4 L3 and the Structurizr path, and image export.
- Moving `/journey` onto the shared template.

## Artifacts

- Plan for #1919 (Tech Lead), with the owner decisions of 2026-10-29 and the design review round 1 fixes.
- [#1919](https://github.com/me2resh/apexyard/issues/1919), PR 1 of 3.
- Related decisions:
  - [AgDR-0003](AgDR-0003-mermaid-c4-for-diagrams.md): Mermaid C4 as the diagram format. Amended for `--html` runs.
  - [AgDR-0016](AgDR-0016-journey-html-rendering.md): `/journey` HTML rendering. Precedent, unchanged.
  - [AgDR-0026](AgDR-0026-dfd-skill-as-source-of-truth.md): `/dfd` as the DFD source of truth. Its deferred Option D is built here.
  - [AgDR-0035](AgDR-0035-per-feature-diagrams.md): per-feature diagrams. Unchanged.
  - [AgDR-0248](AgDR-0248-process-bpmn-grid-layout.md): Python grid layout for `/process`. Precedent, unchanged.

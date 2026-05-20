---
name: feature-diagram
description: Per-feature Mermaid flowchart — routes / models / jobs / screens. Consumes /extract-features inventory.
argument-hint: "<feature-slug> [project-name] [--force]"
allowed-tools: Bash, Read, Grep, Glob, Write, Edit
---

# /feature-diagram — Per-feature Mermaid Sub-graph

Reads the Feature Inventory at `projects/<name>/feature-inventory.md` (produced by `/extract-features`) and writes a per-feature Mermaid `flowchart LR` showing the **HTTP routes, data models, async jobs, and UI screens** that participate in one feature. Output: `projects/<name>/features/<slug>.md` (one file per feature).

This skill closes the gap left by the rest of the architecture-doc family:

| Skill | Slice |
|-------|-------|
| `/c4` | Whole-system topology (L1 + L2) |
| `/dfd` | Whole-system data flows + trust boundaries |
| `/process` | One business process (BPMN control flow) |
| `/journey` | One feature, product-facing user flow (HTML modal-per-page) |
| `/feature-diagram` (this skill) | **One feature, architectural slice** (Mermaid flowchart) |

See `AgDR-0035-per-feature-diagrams.md` for the design rationale.

## Path resolution

Read the per-project docs dir via `portfolio_projects_dir` from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches that path:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
projects_dir=$(portfolio_projects_dir)
```

Defaults match today's single-fork layout (`./projects`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir}` keys in `.claude/project-config.json` — the helper resolves whichever mode they're in. See `docs/multi-project.md`.

## Usage

```
/feature-diagram create-order                       # current project (cwd inside workspace/<name>/ or single-project fork)
/feature-diagram create-order curios-dog            # registered project
/feature-diagram reset-password --force             # overwrite existing diagram
```

If `<project-name>` is omitted and cwd is the ops-fork root with multiple registered projects, the skill asks which project's inventory to read.

## Output location

```
projects/<name>/features/<slug>.md                  ← the per-feature diagram (one file per feature)
projects/<name>/feature-inventory.md                ← updated to link the Feature column to the new file
```

The `features/` directory is created if missing.

## Activated role

When `/feature-diagram` runs, activate the **[Tech Lead](../../../roles/engineering/tech-lead.md)** role — they own architectural slicing and the "which surfaces participate in this feature" view. See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Process

### 1. Resolve the target

- If `<project-name>` is given and the registry has it → use that project.
- If no `<project-name>` and cwd is inside `workspace/<name>/` → use that project.
- If no `<project-name>` and cwd is the ops fork root → ask which registered project (list from `apexyard.projects.yaml`).
- If exactly one project is registered → use it without asking.

### 2. Locate the inventory

The inventory file must exist at `<projects_dir>/<name>/feature-inventory.md`. If missing, stop and tell the operator:

```
No feature inventory at projects/<name>/feature-inventory.md.
Run /extract-features <project> first — that produces the inventory
this skill reads from.
```

### 3. Resolve the feature slug

The slug matches a row in the inventory's consolidated feature matrix. Match in this order:

1. **Exact slug match** in an existing `[link text](features/<slug>.md)` cell — re-runs.
2. **Feature title match** (kebab-case the title and compare) — e.g. operator passes `create-order` and a row says `Create order`.
3. **Substring match** — e.g. `password` matches `Reset password via email`. Ambiguous matches (≥ 2 rows) ask the operator to disambiguate.

If no match → exit 2 with a helpful message listing the available slugs:

```
No feature matches slug 'creat-order' in projects/<name>/feature-inventory.md.

Available slugs:
  create-order
  reset-password-via-email
  bulk-delete-users
  ...

Re-run with one of these, or check the inventory file.
```

### 4. Extract the row's surfaces

For the matched row, parse the inventory's per-axis findings tables (HTTP routes, Data models, Async jobs, UI screens) and collect every element whose `Notes` / `File` / `Source` column ties back to this feature.

The inventory's row has a `Source` column that already names the axes that corroborated the feature (e.g. `route + test + UI`, `model only`). Use that as the primary filter:

| `Source` says | Subgraphs populated |
|---------------|---------------------|
| `route + test + UI + job` | All four (Routes, Screens, Jobs; Models if any route writes to one) |
| `route + UI` | Routes + Screens |
| `model only` | Models (plus a coverage-gap note) |
| `doc only` | Empty diagram with a coverage-gap note pointing at the README/CHANGELOG entry |

When the inventory row references specific handlers / models / jobs / components by file path (the per-axis tables in the inventory are keyed by `File`), follow those references and include each as a node in the matching subgraph.

### 5. Generate the Mermaid

Build a `flowchart LR` with four named subgraphs:

```mermaid
flowchart LR
    subgraph Screens["UI Screens"]
        screen_<id>["<Display name><br/>(<file>)"]
        ...
    end
    subgraph Routes["HTTP Routes"]
        route_<id>["<METHOD> <path><br/>(<file>)"]
        ...
    end
    subgraph Models["Data Models"]
        model_<id>["<Name><br/>(<file>)"]
        ...
    end
    subgraph Jobs["Async Jobs"]
        job_<id>["<Name><br/>(<file>)"]
        ...
    end

    %% Edges inferred from the inventory row
    screen_<id> -->|submits| route_<id>
    route_<id> -->|reads/writes| model_<id>
    route_<id> -->|enqueues| job_<id>
    job_<id> -->|reads/writes| model_<id>
```

**Empty subgraphs** stay visible — render `<Subgraph>_empty["(none)"]` as a placeholder so the four-quadrant shape is constant across features:

```
subgraph Jobs["Async Jobs"]
    Jobs_empty["(none)"]
end
```

**Node IDs** are stable: `screen_<slug>`, `route_<slug>`, `model_<slug>`, `job_<slug>` where `<slug>` is a kebab-case-ified version of the element's name. Stability matters because operators may hand-add a comment or annotation under a specific node ID; re-runs should keep those grounded.

**Edge inference rules** — same as documented in AgDR-0035:

| Source axis | Target axis | Edge label |
|-------------|-------------|------------|
| Screen | Route | `"submits"` if the screen has form fields; `"calls"` otherwise |
| Route | Model | `"reads/writes"` |
| Route | Job | `"enqueues"` |
| Job | Model | `"reads/writes"` (only if the inventory row mentions both as participating) |

Don't invent edges. If the inventory row doesn't corroborate a screen → route mapping (no shared URL prefix, no shared component name), don't draw the edge — emit the nodes only and add a one-line coverage-gap note at the bottom of the file.

### 6. Write the file

Path: `<projects_dir>/<name>/features/<slug>.md`. Output template:

````markdown
# <Feature title>

> Per-feature architectural slice for **<Feature title>**. Generated from the consolidated feature matrix in [`../feature-inventory.md`](../feature-inventory.md).

**Status**: <Active | Deprecated | Untested | Documented but not in code>
**Source axes**: <route + test + UI + job>
**Notes**: <Notes column from the inventory row>

## Diagram

```mermaid
flowchart LR
    ...
```

## Participating elements

### HTTP Routes (<N>)

| Method | Path | Handler | File |
|--------|------|---------|------|
| ... | ... | ... | ... |

### Data Models (<N>)

| Model | Fields | File |
|-------|--------|------|
| ... | ... | ... |

### Async Jobs (<N>)

| Job | Trigger | Handler | File |
|-----|---------|---------|------|
| ... | ... | ... | ... |

### UI Screens (<N>)

| Route | Component | Fields | File |
|-------|-----------|--------|------|
| ... | ... | ... | ... |

## Coverage gaps

- <Any edges the inventory didn't corroborate; any axes that came up empty>

---

_Generated by `/feature-diagram` on YYYY-MM-DD. Re-run when the feature's surfaces change._
````

Behaviour on existing file:

- **File doesn't exist** → write directly.
- **File exists, no `--force`** → prompt the operator with a default-no offer to overwrite. Print a diff against the proposed content if possible.
- **File exists, `--force`** → overwrite without prompting; print a one-line `Overwriting <path>` to stderr.

### 7. Update the inventory back-link

In `<projects_dir>/<name>/feature-inventory.md`'s **consolidated feature matrix table**, replace the matched row's `Feature` cell with a markdown link:

```
| 1 | [Create order](features/create-order.md) | API + UI | Active | route + test + UI | POST /api/orders; charges Stripe; sends confirmation email |
```

Idempotent — if the cell already contains a link to the same target file, leave it. If the cell contains a link to a different target file (rare; manual rename), overwrite.

If the inventory is read-only (no write permission, or the operator passed `--no-update-inventory`) the back-link step is skipped with a one-line warning.

### 8. Lint the generated Mermaid

Run `lint.sh` against the output file:

```bash
SKILL_DIR="$(dirname "$(realpath "$0")")"
"$SKILL_DIR/lint.sh" "$out_file" || lint_rc=$?
```

The lint wraps the shared `_lib-mermaid-lint.sh` — extracts the `` ```mermaid `` flowchart block and validates each via `mmdc` (mermaid-cli). Graceful-degrades when Node / npx is unavailable (exit 3, advisory only).

Treat exit 1 (parse error) as a hard fail — print the lint output, ask the operator whether to (a) auto-regenerate the offending block, (b) keep the file as-is and fix by hand, or (c) re-run with `--skip-lint` if `mmdc` is misbehaving. Exit 3 (Node missing) prints a one-line warning and proceeds.

### 9. Confirm to the user

```
✓ <project>: per-feature diagram written

  Diagram: <projects_dir>/<name>/features/<slug>.md
  Inventory back-link: updated row <N> in feature-inventory.md

  Routes: 3   Models: 2   Jobs: 1   Screens: 1
  Mermaid lint: 1 of 1 block parsed cleanly

Preview: open the file on GitHub — Mermaid renders inline.
Re-run /feature-diagram <slug> --force when the feature's surfaces change.
```

## Rules

1. **Read-only against the codebase.** Never modify the project's source. Only writes to `projects/<name>/features/<slug>.md` and updates the inventory's back-link.
2. **The inventory is a hard dependency.** If `feature-inventory.md` doesn't exist, refuse with a pointer to `/extract-features`. Don't auto-run it (that's a heavyweight scan; the operator should know they're triggering it).
3. **Don't auto-overwrite.** Existing diagrams require explicit `--force`. The diagrams may have been hand-edited.
4. **Empty subgraphs stay visible.** Four quadrants every time; render `(none)` placeholders so the reader's eye doesn't have to re-orient between features.
5. **Don't invent edges.** Every edge must trace to a column in the inventory row. Missing corroboration becomes a coverage-gap note, not a fabricated arrow.
6. **Stable node IDs.** `screen_<slug>` / `route_<slug>` / `model_<slug>` / `job_<slug>` — slug is kebab-case-ified element name. Reproducibility matters; operators may annotate by ID.
7. **Footer signature is mandatory.** Every generated file ends with the `Generated by /feature-diagram on YYYY-MM-DD` line so future readers know it's regenerable.
8. **Refuse if the slug doesn't match a row.** Exit 2 with the list of available slugs — no silent best-guess fallback.

## When to use this

| Trigger | Use `/feature-diagram`? |
|---------|-------------------------|
| Onboarding a new engineer to a specific feature | Yes — pairs with `/handover` and `/extract-features` |
| Planning a refactor scoped to one feature | Yes — visualises the blast radius before code edits |
| Greenfield rewrite, slicing the v1 scope by feature | Yes — each "must-have v1" feature gets a per-feature diagram showing what must be preserved |
| Major arch change to one feature (new model added, new job triggered) | Yes — re-run with `--force` |
| Whole-system view | No — use `/c4` (topology) or `/dfd` (data flows) |
| User-flow preview for stakeholders | No — use `/journey` (product-facing HTML) |

## Out of scope (v1)

- **Cross-feature diagrams** (showing how features depend on each other) — listed as out-of-scope in #288.
- **Per-feature sequence diagrams** — use `templates/architecture/sequence.md` manually if needed.
- **Trust-boundary overlays** — that's `/dfd`'s slice. If the operator wants security-scoped feature analysis, run `/dfd` and `/feature-diagram` side by side.
- **Auto-running `/extract-features`** — the inventory is a hard dependency, not an optional auto-trigger.
- **Cross-project per-feature diagrams** — single project per invocation. Multi-project per-feature is a separate concern.

## Anti-patterns

- **Don't substitute `/feature-diagram` for `/c4`.** The per-feature slice shows ONE feature's surfaces. System-wide topology lives in `/c4`.
- **Don't run `/feature-diagram` for every row on every PR.** It's refresh-on-arch-change, not per-PR. The whole inventory only changes when features ship; the per-feature diagrams only change when the feature's routes / models / jobs / screens change.
- **Don't hand-edit a generated diagram and lose the footer.** Re-runs detect the footer; without it the skill can't tell if a file is regenerable. If you must hand-edit, keep the footer line in place.
- **Don't treat coverage gaps as failures.** The inventory has gaps by design (the scanner can't see business rules, permission matrices, or implicit features). Per-feature diagrams inherit those gaps — that's a feature, not a bug; the gaps are surfaced explicitly so a human can fill them in.

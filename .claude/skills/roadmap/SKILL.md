---
name: roadmap
description: Update, create, or reprioritise the product roadmap. Supports adding, removing, and reordering milestones, then renders a markdown table per milestone.
argument-hint: "[add|remove|reorder|show] [item]"
allowed-tools: Bash, Read, Edit, Write, Grep, Glob
---

# /roadmap — Product Roadmap

Manage the product roadmap as a single durable file. The skill is intentionally low-ceremony: a roadmap is a markdown file with milestones, each containing a table of items. `/roadmap` reads it, edits it, and renders it.

## Activated role

When `/roadmap` runs, activate the **[Head of Product](../../../roles/product/head-of-product.md)** role — they own roadmap prioritisation, strategic sequencing, and milestone decisions. For adding a specific item with a PRD, chain to `/write-spec` which activates the [Product Manager](../../../roles/product/product-manager.md) instead. For items that require data-driven reprioritisation, involve the [Product Analyst](../../../roles/product/product-analyst.md).

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Usage

```
/roadmap                          # show current roadmap
/roadmap add "OAuth login" Q3 P0  # add an item to a milestone
/roadmap remove "OAuth login"     # remove an item
/roadmap reorder                  # interactive reordering
/roadmap show Q3                  # show a single milestone
```

## File location

| Mode | File |
|------|------|
| **multi-project mode** (default) | `projects/<name>/roadmap.md`, where `<name>` is either passed via `--project` or the current working directory |
| **single-project mode** | `ROADMAP.md` at the project root |

In multi-project mode (the default), without `--project`, the skill asks which project's roadmap to operate on, listing the registry.

## File format

```markdown
# Product Roadmap

> Last updated: YYYY-MM-DD
> Owner: @octocat

## Now (current cycle)

| ID | Item | Priority | Status | Owner | Notes |
|----|------|----------|--------|-------|-------|
| RM-001 | CSV export | P0 | in-progress | @alice | GH#42 |
| RM-002 | OAuth login | P0 | not-started | @bob | depends on AgDR-0007 |

## Next (1-3 cycles out)

| ID | Item | Priority | Status | Owner | Notes |
|----|------|----------|--------|-------|-------|
| RM-003 | Multi-currency | P1 | not-started | – | |

## Later (3+ cycles out)

| ID | Item | Priority | Status | Owner | Notes |
|----|------|----------|--------|-------|-------|

## Done

| ID | Item | Shipped | PR |
|----|------|---------|-----|
| RM-000 | Health endpoint | 2026-04-05 | #41 |
```

The default milestones are **Now / Next / Later / Done** (Now-Next-Later format). Custom milestones (Q1/Q2/Q3 or v1.0/v1.1/v2.0) are also accepted.

## Process

### show (default)

1. Read the roadmap file
2. Render each non-empty milestone as a table
3. Print a footer summary:
   ```
   12 items · 5 in Now · 4 in Next · 3 in Later · 8 Done
   ```

### add `<item>` `<milestone>` `<priority>`

1. Read the roadmap file
2. Find the next available `RM-NNN` ID
3. Append a row to the right milestone's table
4. Default `Status: not-started`, `Owner: –`
5. Update the `Last updated` date
6. Write the file back

### remove `<item-or-id>`

1. Locate the row by ID or fuzzy title match
2. Confirm before deleting
3. Remove the row, update the date

### reorder

1. List items in the chosen milestone with their position
2. Ask for the new ordering (e.g. `2,1,3,4`)
3. Rewrite the table in the new order

### move `<id>` `<new-milestone>`

1. Find the row by ID
2. Remove it from the current milestone
3. Append it to the target milestone
4. Update the date

### close `<id>`

1. Find the row by ID across Now / Next / Later
2. Move it to Done
3. Add `Shipped` date and `PR` column reference (ask user for PR # if it can't be inferred)

## Linking to GitHub Issues

If the user passes `--with-issues`, also create or update GitHub Issues to mirror the roadmap:

```bash
# For each item in Now and Next without a GH link in Notes:
gh issue create \
  --title "[Roadmap] {item}" \
  --body "Tracking issue for roadmap item {RM-NNN}" \
  --label "roadmap,{priority}"
```

Then write the issue number back into the Notes column.

## Output format (show)

```
ROADMAP — example-app — last updated 2026-04-06
================================================

NOW (current cycle)
| ID     | Item            | Priority | Status      | Owner  | Notes                |
|--------|-----------------|----------|-------------|--------|----------------------|
| RM-001 | CSV export      | P0       | in-progress | @alice | GH#42                |
| RM-002 | OAuth login     | P0       | not-started | @bob   | depends on AgDR-0007 |

NEXT (1–3 cycles out)
| ID     | Item            | Priority | Status      | Owner | Notes |
|--------|-----------------|----------|-------------|-------|-------|
| RM-003 | Multi-currency  | P1       | not-started | –     |       |

LATER
(empty)

DONE (last 5)
| ID     | Item            | Shipped    | PR  |
|--------|-----------------|------------|-----|
| RM-000 | Health endpoint | 2026-04-05 | #41 |

Summary: 3 active · 0 later · 1 done
Owner: @octocat
```

## Priorities

| Priority | Meaning |
|----------|---------|
| P0 | Must ship in current cycle |
| P1 | Should ship soon |
| P2 | Nice to have |
| P3 | Speculative |

## Status values

| Status | Meaning |
|--------|---------|
| not-started | No work yet |
| in-progress | Active work, branch/PR exists |
| blocked | Waiting on something — note in Notes column |
| in-review | PR open, awaiting review |
| done | Shipped (auto-moves to Done milestone) |

## Rules

1. **One file = one project's roadmap** — no shared roadmaps across projects
2. **IDs are stable** — `RM-001` never changes once assigned
3. **Done is append-only** — items move to Done, never out of it
4. **Update `Last updated`** on every write
5. **Confirm destructive ops** — `remove`, `reorder` ask first
6. **Mode-aware** — write to `ROADMAP.md` (single) or `projects/<name>/roadmap.md` (multi)
7. **Don't auto-create issues unless asked** — `--with-issues` is opt-in
8. **Preserve markdown formatting** — don't reflow rows or change column widths unnecessarily

## Related skills

- `/write-spec` — once a roadmap item is approved, write its PRD
- `/stakeholder-update` — pulls "Now" and "Done" sections to summarise progress
- `/idea` — for ideas not yet on the roadmap

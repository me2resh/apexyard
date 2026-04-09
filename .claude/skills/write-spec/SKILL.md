---
name: write-spec
description: Write a feature spec or PRD from a problem statement or feature idea. Use when creating product requirements documents.
argument-hint: "<feature or problem statement>"
---

# /write-spec — Feature Specification

Write a feature specification or product requirements document (PRD).

## Activated role

When `/write-spec` runs, activate the **[Product Manager](../../../roles/product/product-manager.md)** role — they own PRD creation, user stories, and acceptance criteria. For roadmap-level prioritisation calls, escalate to the **[Head of Product](../../../roles/product/head-of-product.md)**.

Design-heavy features should also involve the **[UX Designer](../../../roles/design/ux-designer.md)** (for user flows) and the **[UI Designer](../../../roles/design/ui-designer.md)** (for component specs) once the PRD has a problem statement. Technical feasibility review happens at the Tech Design phase, not here — the `/write-spec` output hands off to the [Tech Lead](../../../roles/engineering/tech-lead.md) who activates for Phase 2.

See [`.claude/rules/role-triggers.md`](../../rules/role-triggers.md) for the full activation protocol.

## Usage

```
/write-spec SSO support for enterprise
/write-spec Users want to export data as CSV
/write-spec We need better onboarding
```

## Workflow

### 1. Understand the Feature

Accept any of: a feature name, a problem statement, a user request, or a vague idea.

### 2. Gather Context

Ask conversationally:

- **User problem** — what problem does this solve? Who experiences it?
- **Target users** — which user segment(s)?
- **Success metrics** — how will we know this worked?
- **Constraints** — technical, timeline, dependencies?
- **Prior art** — has this been attempted before?

### 3. Pull Context from Connected Tools

If the project has integrations available:

- **GitHub Issues** (the default tracker) — search for related issues, epics, or features in the project's repo. Teams using other trackers (Linear, Jira) can substitute the equivalent search.
- **Notion / Confluence** — search for related research, specs, or design docs
- **Figma** — pull related mockups or wireframes

### 4. Generate the PRD

Use `templates/prd.md` as the base. The PRD should include:

```markdown
# {Feature Name} — PRD

## Problem Statement
## Goals
   3–5 specific, measurable outcomes

## Non-Goals
   3–5 things explicitly out of scope

## User Stories
   As a [user type], I want [capability] so that [benefit]

## Requirements
### Must-Have (P0)
### Nice-to-Have (P1)
### Future (P2)

## Success Metrics
### Leading Indicators (days–weeks)
### Lagging Indicators (weeks–months)

## Open Questions
## Timeline
```

### 5. Review and Iterate

After generating the draft: ask if sections need adjustment, offer follow-ups.

### 6. Create the Tracking Ticket

Offer to create an epic / feature ticket in the team's tracker with the PRD content.

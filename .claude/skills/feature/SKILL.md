---
name: feature
description: Create a structured feature request ticket with user story, acceptance criteria, and design notes. Use when proposing a new user-facing feature.
argument-hint: "<short title of the feature>"
allowed-tools: Bash, Read, Write
---

# /feature — Create a Feature Request Ticket

Creates a structured GitHub Issue for a new feature with a user story, acceptance criteria, and design notes. Asks guided questions, shows the formatted ticket for confirmation, then creates the issue.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## Usage

```
/feature Profile picture upload
/feature Arabic language support
/feature Likes on answers
```

## Process

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexyard.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this feature for?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Parse or ask for the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the feature? Give me a short title.
```

### 3. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next.

**a) User Story**

```
Who is this for and what do they want?
Format: As a [persona], I want [goal] so that [benefit].
```

If the user gives a casual answer ("users should be able to upload photos"), restructure it into the user story format and confirm.

**b) Acceptance Criteria**

```
What are the acceptance criteria? List the specific things that must be true when this is done.
(You can write them as bullet points — I'll format them as checkboxes.)
```

**c) Design Notes**

```
Any design notes? (screenshots, mockups, Figma links, or "no UI changes")
```

If the user says something like "no" or "none", use "No UI changes" as the value.

**d) Priority**

```
Priority?
1. P0 — must-have for current milestone
2. P1 — ship soon after launch
3. P2 — future / v2+
```

**e) Out of Scope (optional)**

```
Anything explicitly out of scope? (or press Enter to skip)
```

### 4. Show the formatted ticket for confirmation

Display the full ticket:

```
Here's the ticket I'll create:

---
**[Feature] {title}**

## User Story
As a {persona}, I want {goal} so that {benefit}.

## Acceptance Criteria
- [ ] {criterion 1}
- [ ] {criterion 2}
- [ ] ...

## Design Notes
{notes}

## Out of Scope
{out of scope or "—"}

## Effort Estimate
TBD
---

Labels: enhancement, {P0|P1|P2}
Repo: {owner/repo}

Create this ticket? (yes / edit / cancel)
```

### 5. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 6. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[Feature] {title}" \
  --label "enhancement,{priority}" \
  --body "{formatted body}"
```

### 7. Return the URL

```
Created: {owner/repo}#{number} — {title}
{url}
```

## Rules

1. **One question at a time.** Never batch questions. Wait for each answer.
2. **Always confirm before creating.** Show the full ticket and get explicit "yes".
3. **User story format is required.** Restructure casual answers into As a / I want / So that.
4. **At least one acceptance criterion.** Don't create tickets with empty ACs.
5. **Labels auto-applied.** `enhancement` always, plus the priority label. The priority label scheme is read from `.claude/project-config.*.json` → `.ticket.label_priority_scheme` (default `P0,P1,P2,P3`); forks that use a different scheme (e.g. `priority-p0`) configure it there.
6. **Title prefix.** `[Feature]` by default. The accepted prefix list is read from `.claude/project-config.*.json` → `.ticket.prefix_whitelist`; if a fork has added alternate feature-class prefixes (e.g. `[Enhancement]`), this skill will accept them. See apexyard#109 for the schema.

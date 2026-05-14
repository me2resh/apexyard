---
name: task
description: Create a structured technical task ticket with driver, scope, and acceptance criteria. Use for tech debt, infrastructure work, refactoring, or non-user-facing changes.
argument-hint: "<short title of the task>"
allowed-tools: Bash, Read, Write
---

# /task — Create a Technical Task Ticket

Creates a structured GitHub Issue for a technical task with driver (why), scope (what), acceptance criteria, and risks. Used for tech debt, infrastructure, refactoring, dependency updates, or any non-user-facing work that doesn't fit /feature or /bug.

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
/task Set up PR-triggered CI pipeline
/task Extract shared LikeCount component
/task Migrate from DiceBear to local avatars
```

## Process

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexyard.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this task for?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Parse or ask for the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the task? Give me a short title.
```

### 3. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next.

**a) Driver**

```
Why is this work needed? (upstream ticket, tech debt rationale, Rex recommendation, dependency requirement, etc.)
```

**b) Scope**

```
What specifically needs to change? Be concrete — which files, services, or systems are affected.
```

**c) Acceptance Criteria**

```
What are the acceptance criteria? What must be true when this is done?
```

**d) Priority**

```
Priority?
1. P0 — blocks other work
2. P1 — important, schedule soon
3. P2 — nice to have, do when convenient
```

**e) Risks / Dependencies (optional)**

```
Any risks or dependencies? (what could block this, what depends on it, or Enter to skip)
```

### 4. Show the formatted ticket for confirmation

Display the full ticket:

```
Here's the ticket I'll create:

---
**[{Chore|Refactor|Test|CI}] {title}**

## Driver
{why this work is needed}

## Scope
{what specifically needs to change}

## Acceptance Criteria
- [ ] {criterion 1}
- [ ] {criterion 2}
- [ ] ...

## Risks / Dependencies
{risks or "None identified"}
---

Labels: {type}, {P0|P1|P2}
Repo: {owner/repo}

Create this ticket? (yes / edit / cancel)
```

The title prefix is derived from the content, and must come from the project's configured prefix whitelist (`.claude/project-config.*.json` → `.ticket.prefix_whitelist`, default list at `.claude/project-config.defaults.json`). Shipped defaults map as follows:

- Testing work → `[Testing]`
- CI/CD work → `[CI]`
- Refactoring → `[Refactor]`
- Documentation-only change → `[Docs]`
- Everything else → `[Chore]`

A fork that extends the whitelist (e.g. adds `[Security]`, `[Perf]`, `[Scaffold]`) automatically gains the option here — the skill reads the live config, it does not hardcode the list. See apexyard#109 for the schema and how to extend.

### 5. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 6. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[{type}] {title}" \
  --label "{priority}" \
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
3. **Driver is required.** Every technical task needs a "why".
4. **At least one acceptance criterion.** Don't create tasks with empty ACs.
5. **Labels auto-applied.** Priority label always applied.
6. **Title prefix.** Derived from the nature of the work: Testing, CI, Refactor, or Chore.

---
name: feature
description: Create a structured feature ticket (user story, acceptance criteria, design notes) for a new user-facing feature.
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

### 0. Write the active-issue-skill marker (REQUIRED — me2resh/apexyard#268)

Before any `gh issue create` (or other tracker CLI), write this skill's name to the active-issue-skill marker so `require-skill-for-issue-create.sh` lets the command through. At skill entry:

```bash
ops_root="$(r=$PWD;while [ ! -f \"$r/onboarding.yaml\" ] && [ \"$r\" != / ];do r=${r%/*};done;echo $r)"
mkdir -p "$ops_root/.claude/session"
echo "feature" > "$ops_root/.claude/session/active-issue-skill"
```

Remove the marker on **every** exit path (success, early-exit, user cancel, error):

```bash
rm -f "$ops_root/.claude/session/active-issue-skill"
```

The `clear-issue-skill-marker.sh` SessionStart hook sweeps stale markers from killed sessions, but a clean exit should never leave one behind. See AgDR-0030.

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

### 4. Resolve the feature body template

Resolve the feature body template via the portfolio helper so adopter overrides win when present:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
template=$(portfolio_resolve_template tickets/feature.md)   # → custom-templates/tickets/feature.md if present, else templates/tickets/feature.md
```

Single-fork adopters (no `portfolio` block) and adopters with no override fall straight through to `templates/tickets/feature.md`. Adopters who want a customised feature-body shape drop their version at `<private_repo>/custom-templates/tickets/feature.md`. See `templates/README.md` for the path-mirroring convention.

**Backward-compat fallback**: if `portfolio_resolve_template` returns empty (template file missing — partial adopter setup), fall back to the inline heredoc body below and print a one-line WARN on stderr (`WARN: tickets/feature.md template missing — using inline fallback`). This preserves the pre-refactor behaviour for adopters whose installations don't yet have the new template files.

### 5. Show the formatted ticket for confirmation

Substitute the gathered inputs into the resolved template (or the inline heredoc fallback), then display the full ticket using the resolved shape (the default `templates/tickets/feature.md` shape is reproduced below):

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

## Glossary
| Term | Definition |
|------|------------|
| {term} | {definition} |
---

Labels: enhancement, {P0|P1|P2}
Repo: {owner/repo}

Create this ticket? (yes / edit / cancel)
```

### 6. Handle response

- **yes** / **looks good** / **go** → create the issue
- **edit** / **change X** → ask what to change, update, re-show
- **cancel** / **no** → abort

### 7. Create the GitHub Issue

```bash
gh issue create --repo {owner/repo} \
  --title "[Feature] {title}" \
  --label "enhancement,{priority}" \
  --body "{formatted body}"
```

### 8. Return the URL

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

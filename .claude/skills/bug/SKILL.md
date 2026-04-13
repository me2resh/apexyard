---
name: bug
description: Create a structured bug report with Given/When/Then scenario, repro steps, and severity. Use when reporting a bug or unexpected behavior.
argument-hint: "<short description of the bug>"
allowed-tools: Bash, Read, Write
---

# /bug — Create a Bug Report Ticket

Creates a structured GitHub Issue for a bug with Given/When/Then scenario, repro steps, environment, and severity. Asks guided questions, shows the formatted ticket for confirmation, then creates the issue.

## Usage

```
/bug Profile picture upload fails
/bug RTL resets on navigation
/bug Follow button state not persisted
```

## Process

### 1. Resolve the target repo

Read `.claude/session/current-ticket` to determine which repo we're working in. If no active ticket, check `apexstack.projects.yaml` for managed projects. If only one project, use it. If multiple, ask:

```
Which project is this bug in?
```

If no projects are registered, ask for the repo in `owner/repo` format.

### 2. Parse or ask for the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the bug? Give me a short description.
```

### 3. Gather details (one question at a time)

Ask conversationally — do NOT batch all questions. Wait for each answer before asking the next.

**a) Bug Scenario**

```
Describe the bug scenario:
- Given: what's the starting state?
- When: what action triggers the bug?
- Then: what happens (the broken behavior)?
- Expected: what should happen instead?
```

If the user gives a casual description, restructure it into Given/When/Then/Expected format and confirm.

**b) Repro Steps**

```
What are the exact steps to reproduce?
```

**c) Severity**

```
How severe is this?
1. P0 — blocks a core feature, must fix immediately
2. P1 — important, fix soon
3. P2 — minor, fix when convenient
```

**d) Environment (optional)**

```
Any environment details? (browser, device, staging/prod, or Enter to skip)
```

**e) Investigation Notes (optional)**

```
Any initial investigation? (root cause hypothesis, relevant code paths, or Enter to skip)
```

### 4. Show the formatted ticket for confirmation

Display the full ticket:

```
Here's the ticket I'll create:

---
**[{P0|P1|P2}] {title}**

## Bug Scenario
**Given** {precondition}
**When** {action}
**Then** {unexpected result}
**Expected** {correct behavior}

## Repro Steps
1. {step 1}
2. {step 2}
3. ...

## Environment
{environment or "Not specified"}

## Severity
{P0-critical / P1-important / P2-later}

## Investigation Notes
{notes or "—"}
---

Labels: bug, {P0|P1|P2}
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
  --title "[{P0|P1|P2}] {title}" \
  --label "bug,{priority}" \
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
3. **Given/When/Then is required.** Restructure casual descriptions into the format.
4. **At least one repro step.** Don't create bugs without repro.
5. **Labels auto-applied.** `bug` always, plus the severity label.
6. **Title prefix.** Severity in brackets: `[P0]`, `[P1]`, or `[P2]`.

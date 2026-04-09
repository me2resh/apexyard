---
name: idea
description: Submit a new product idea, feature concept, or internal tool proposal to the ideas backlog. Use when capturing a new product concept that hasn't been triaged yet.
argument-hint: "<short title of the idea>"
allowed-tools: Bash, Read, Edit, Write
---

# /idea — Submit a New Product Idea

Capture a new product, feature, or internal-tool idea so it lands somewhere durable instead of evaporating in chat. This skill is intentionally lightweight: it adds an entry to the ideas backlog and (optionally) creates a tracking GitHub Issue. It does **not** replace `/write-spec` — that comes later, after the idea has been triaged.

## Usage

```
/idea Auto-tag inbound emails by intent
/idea Internal CLI for resetting staging data
/idea New product: AI design system linter
```

## Where the entry goes

Every idea lands in `projects/ideas-backlog.md` at the root of your ops repo (your fork of apexstack). One shared backlog for every project — triage decides which project ends up owning a given idea.

If the file doesn't exist yet, create it with a header and a table.

## Process

### 1. Parse the title

Take the title from `$ARGUMENTS`. If empty, ask:

```
What's the idea? Give me a short title (1 line).
```

### 2. Gather metadata

Ask conversationally (one question at a time, don't batch):

- **Category**: New Product / Feature / Internal Tool / Process
- **Submitter**: who's proposing it (default to current git user)
- **One-line description**: what would it do? Who's it for?

Don't go deeper than that — this is a lightweight capture, not a spec.

### 4. Compute the next ID

```bash
# Find the highest existing IDEA-NNN in the backlog file
grep -oE 'IDEA-[0-9]+' <backlog-file> 2>/dev/null | sort -V | tail -1
# Increment by 1, or start at IDEA-001 if none exist
```

### 5. Append the entry

If the backlog file doesn't exist, create it with this header:

```markdown
# Ideas Backlog

Lightweight capture of product ideas, feature concepts, and internal tool proposals.
Use `/idea` to add a new entry. Triage moves entries into `/write-spec`, then into a GitHub Issue.

| ID | Title | Category | Submitter | Date | Status | Description |
|----|-------|----------|-----------|------|--------|-------------|
```

Append a new row:

```markdown
| IDEA-NNN | {title} | {category} | {submitter} | YYYY-MM-DD | NEW | {one-line description} |
```

### 6. Offer the tracking issue

After the entry is appended, ask:

```
Would you like me to create a tracking GitHub Issue for IDEA-NNN? (y/n)
```

If yes, create one with the `enhancement` and `idea` labels (creating the labels if needed):

```bash
gh issue create \
  --title "[Idea] {title}" \
  --body "$(cat <<'EOF'
## Idea
{one-line description}

## Category
{category}

## Submitter
{submitter}

## Backlog Entry
IDEA-NNN — see backlog file.

## Next Step
Triage. Decide whether to spec, schedule, or close.
EOF
)" \
  --label "idea,needs-triage"
```

If the issue is created, append the issue URL to the backlog row's Description column as `(GH#NN)`.

## Output

```
Captured: IDEA-NNN — {title}
Backlog: {file path}
Status: NEW
Tracking issue: {url or "skipped"}

Next: triage with the team, then `/write-spec` if it survives.
```

## Rules

1. **Lightweight only** — `/idea` captures, it does not spec. Don't ask for goals, metrics, or requirements here.
2. **Always assign an ID** — `IDEA-NNN`, zero-padded to 3 digits.
3. **One row per idea** — never edit existing rows from this skill; new ideas always append.
4. **Status starts at NEW** — triage changes it later.
5. **Single backlog** — every idea goes into `projects/ideas-backlog.md` at the root of the ops repo; triage assigns it to a project later.
6. **Don't create the issue silently** — always ask first.
7. **Never delete** — superseded ideas get status `SUPERSEDED`, not removal.

## Status values

| Status | Meaning |
|--------|---------|
| NEW | Just captured, not triaged |
| TRIAGED | Reviewed, awaiting decision |
| SPECCED | `/write-spec` produced a PRD |
| SHIPPED | Built and released |
| WONTDO | Triaged out — not pursuing |
| SUPERSEDED | Replaced by a different idea |

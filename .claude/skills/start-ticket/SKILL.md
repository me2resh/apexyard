---
name: start-ticket
description: Declare an active ticket for this session so the ticket-first hook lets code edits through. Accepts either a plain issue number (resolves against the current repo's origin) or a fully-qualified `<owner>/<repo>#<number>` reference. Run this at the start of any coding work.
disable-model-invocation: false
argument-hint: "<issue-number> | <owner/repo>#<number>"
effort: low
---

# /start-ticket - Declare the Active Ticket

Writes `.claude/session/current-ticket` so the `require-active-ticket.sh` PreToolUse hook permits Edit/Write on code paths. Without this marker, the hook blocks edits to anything outside `.claude/`, `docs/`, `projects/*/docs/`, and `*.md`.

This is the mechanical enforcement of the Pre-Build Gate in `.claude/rules/workflow-gates.md` — "do not start coding until the ticket exists".

## Process

### 1. Parse Arguments

Expected forms:
- `42` — plain number, resolves against the current repo. Read `git remote get-url origin` and extract `<owner>/<repo>`. If there's no origin, stop and ask for a fully-qualified reference.
- `me2resh/flat-mate#128` — fully-qualified reference.
- `apexstack#42` — owner defaults to the current org (parsed from the origin URL).

If `$ARGUMENTS` is empty, stop and ask the user which issue they're starting.

**Cross-repo note:** ApexStack governs a portfolio of repos. If the user is in the ops repo (the apexstack fork) but the ticket lives in a managed project's own repo, they should pass the fully-qualified form so the marker records the correct tracker. Each managed project's tickets live in that project's own GitHub repo — tickets do not cross project boundaries.

### 2. Verify the Issue Exists

Run:

```bash
gh issue view <number> --repo <owner/repo> --json number,title,state,url,labels
```

If `state` is not `OPEN`, warn the user and confirm before continuing (sometimes you do want to resume work on a re-opened issue).

If the issue does not exist, stop and report the error — do not write the marker.

### 3. Derive a Branch Suggestion

From the issue title and number, generate: `<type>/<TICKET-ID>-<slug>` where:

- `<type>` guessed from title prefix: `[Feat]` → `feature`, `[Fix]` → `fix`, `[Docs]` → `docs`, `[Chore]` → `chore`, default `feature`
- `<TICKET-ID>` is `GH-<number>` for GitHub Issues, or matches the project's configured `ticket_prefix` from `apexstack.projects.yaml` if set
- `<slug>` = lowercase title, kebab-case, max 40 chars, stopwords trimmed from the edges

Match the convention in `.claude/rules/git-conventions.md`.

### 4. Write the Marker

Create `.claude/session/current-ticket` with:

```
repo=<owner/repo>
number=<number>
title=<title>
url=<url>
suggested_branch=<branch>
started_at=<ISO-8601>
```

Make sure `.claude/session/` exists; create if needed.

### 5. Confirm to the User

Output a single-line confirmation:

```
Active ticket: <owner/repo>#<number> — <title>
Suggested branch: <branch>
```

Do NOT create the branch automatically. The user may already be on a branch, or may want to confirm the branch name first.

## Notes

- `.claude/session/` is gitignored — the marker is per-machine, per-clone.
- Running `/start-ticket` again overwrites the marker (use it when switching tickets).
- To clear the marker without starting a new ticket: `rm .claude/session/current-ticket`.
- Exempt paths (`.claude/`, `docs/`, `projects/*/docs/`, any `*.md`) don't need a ticket — the skill is only required before touching source / config / infra.
- If you're working inside `workspace/<project>/`, the marker lives in THAT clone's `.claude/session/`, not in the ops repo's. Each working copy tracks its own active ticket.

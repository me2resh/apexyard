---
name: inbox
description: Show every item across managed projects that needs the user's attention — PRs to review, issues assigned to them, comments to respond to, blockers. Use to triage the day.
allowed-tools: Bash, Read, Grep, Glob
---

# /inbox — Items Needing Your Attention

Aggregates everything that's currently waiting on **you** across the projects ApexYard manages. Designed to be the first thing you run in a session.

## Usage

```
/inbox
/inbox --me octocat
/inbox --since 24h
```

## Scope

`/inbox` iterates every project in `apexyard.projects.yaml` at the root of your ops repo (your fork of apexyard). If the registry doesn't exist, print a clear error pointing at `docs/multi-project.md`.

## What goes in the inbox

The inbox is grouped by section. Empty sections are omitted.

### 1. PRs awaiting your review

```bash
gh pr list \
  --search "is:open is:pr review-requested:@me" \
  --json number,title,url,headRepository,updatedAt,author \
  --limit 50
```

Run this per `repo:` from the registry (or use `--search "user:your-org"` if you have an org).

### 2. PRs you authored that have changes requested

```bash
gh pr list \
  --search "is:open is:pr author:@me review:changes_requested" \
  --json number,title,url
```

These are blocking **you**, not your reviewers — they're your inbox.

### 3. PRs you authored that are approved and ready to merge

```bash
gh pr list \
  --search "is:open is:pr author:@me review:approved" \
  --json number,title,url,mergeable,mergeStateStatus
```

Filter to ones where `mergeStateStatus` is `CLEAN` — those are ready to merge right now.

### 4. Issues assigned to you

```bash
gh issue list \
  --search "is:open is:issue assignee:@me" \
  --json number,title,url,labels,updatedAt
```

### 5. Issues you opened that have new comments since you last looked

```bash
gh issue list \
  --search "is:open is:issue author:@me commenter:>@me" \
  --json number,title,url,comments,updatedAt
```

(GitHub's search syntax doesn't perfectly express "new comments since you last looked", so use `updatedAt` and filter client-side against a stored "last seen" timestamp if available, otherwise show everything from the last 7 days.)

### 6. Mentions in comments

```bash
gh search issues "mentions:@me is:open" \
  --json number,title,url,repository,updatedAt
```

### 7. PRs failing CI on a branch you authored

```bash
gh pr list \
  --search "is:open is:pr author:@me" \
  --json number,title,url,statusCheckRollup
```

Filter client-side to those where any check is `FAILURE`.

### 8. Blocking labels across managed projects

```bash
gh issue list --label blocked --state open \
  --json number,title,url,labels
```

(Run per project from the registry.)

## Output format

Group everything under headings, project-prefixed:

```
INBOX — 2026-04-06 09:14
=========================

🔴 PRs awaiting your review (3)
  · example-app#42  Add export to CSV         updated 1h ago   https://…
  · billing-api#8   Fix invoice rounding      updated 3h ago   https://…
  · marketing#12    Hero copy refresh         updated 1d ago   https://…

🟡 Your PRs with changes requested (1)
  · example-app#39  Refactor session store    Code Reviewer requested changes   https://…

🟢 Your PRs ready to merge (1)
  · example-app#41  Add health endpoint       2 approvals · CI green            https://…

📬 Issues assigned to you (4)
  · example-app#117 [Bug] Login fails on Safari       priority-high   https://…
  · billing-api#22  [Feature] Multi-currency support  priority-medium https://…
  · …

💬 New comments on issues you opened (2)
  · example-app#98   3 new comments since yesterday    https://…
  · marketing#5      Designer left a comment           https://…

🚨 PRs with failing CI (1)
  · example-app#42   lint job failed                    https://…

🛑 Blocked items (1)
  · billing-api#19   Waiting on API key from vendor     https://…

Summary: 12 items · 3 PRs to review · 1 ready to merge · 1 blocking CI failure
```

If everything is empty:

```
✨ Inbox zero. Nothing waiting on you across {N} projects.
```

## Filters

| Flag | Effect |
|------|--------|
| `--me <user>` | Run as if `<user>` is the current user (default: `@me`) |
| `--since <duration>` | Only items updated in the window (e.g. `24h`, `7d`) |
| `--project <name>` | Limit to one project from the registry |
| `--no-mentions` | Hide the mentions section |

## Rules

1. **Read-only** — never close, comment, or assign anything from this skill
2. **Always sort by recency within each section** — newest updates first
3. **Registry-scoped** — only projects listed in `apexyard.projects.yaml` count; never shell out to "all repos in the org"
4. **Skip empty sections** — don't print headers with `(0)`
5. **Never error on a single project** — if one repo is unreachable, mark it `?` and continue
6. **Always include URLs** — every row needs a clickable link
7. **No noise** — items where you have no possible action shouldn't appear (e.g. PRs you've already approved)

## Related skills

- `/tasks` — same data but flattened into a single ordered TODO list
- `/status` — current project's git/CI snapshot
- `/projects` — portfolio-level health snapshot

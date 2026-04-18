---
name: tasks
description: Generate a flat actionable task list with direct URLs for everything needing your action — PRs to review, issues to triage, comments to respond to, failing CI. Multi-project aware.
allowed-tools: Bash, Read, Grep, Glob
---

# /tasks — Actionable Task List

A single ordered list of "things to click on right now". Where `/inbox` groups items by category, `/tasks` flattens everything into a prioritised TODO with one URL per line. Optimised for "I have 30 minutes, what should I do?".

## Usage

```
/tasks
/tasks --top 10
/tasks --priority high
/tasks --markdown
```

## Scope

Iterates every project in `apexyard.projects.yaml` (the registry at the root of your ops repo).

## Where tasks come from

The task list is the union of:

| Source | Tool |
|--------|------|
| PRs awaiting your review | `gh pr list --search "review-requested:@me is:open"` |
| PRs you authored that are blocked on you (changes requested, conflicts, failing CI) | `gh pr list --search "author:@me is:open review:changes_requested"` |
| Issues assigned to you with high priority | `gh issue list --assignee @me --label priority-high,priority-critical` |
| Issues you opened with new comments | `gh issue list --search "author:@me commenter:>@me is:open"` |
| Mentions in unresolved threads | `gh search issues "mentions:@me is:open"` |
| PR comments awaiting your response | `gh api repos/{repo}/pulls/{n}/comments` filtered to threads where you were mentioned and the last reply isn't yours |
| Open Critical/High issues with no assignee in projects you own | `gh issue list --label priority-critical --assignee none` |
| Failing CI on your authored open PRs | from `statusCheckRollup` |

## Prioritisation

Tasks are scored and sorted. Higher score = closer to the top.

| Signal | Score |
|--------|-------|
| Failing CI on your own PR | +100 |
| PR ready to merge (approved, CI green) — yours | +90 |
| Critical issue assigned to you | +80 |
| PR review requested by name on you | +70 |
| PR review requested on a team you're in | +60 |
| Changes requested on your PR | +50 |
| High-priority issue assigned to you | +40 |
| New comment on an issue you opened | +30 |
| Mention in an open thread | +20 |
| Medium-priority issue assigned to you | +10 |
| Low-priority issue assigned to you | +1 |

Tie-breakers:

1. Older `updatedAt` first (stale things bubble up)
2. Same project as your current working directory first
3. Alphabetical by repo

## Output format

Default (terminal):

```
TASKS — 2026-04-06 09:14
========================
12 actionable items across 3 projects.

  1. [MERGE]  example-app#41  Add health endpoint        — approved + CI green
              https://github.com/your-org/example-app/pull/41
  2. [FIX-CI] example-app#42  CSV export                 — lint job failed
              https://github.com/your-org/example-app/pull/42
  3. [REVIEW] billing-api#8   Fix invoice rounding       — review requested 3h ago
              https://github.com/your-org/billing-api/pull/8
  4. [TRIAGE] example-app#117 [Bug] Login fails Safari   — priority-high, unassigned
              https://github.com/your-org/example-app/issues/117
  5. [REPLY]  marketing#5     Hero copy refresh          — designer commented 1h ago
              https://github.com/your-org/marketing/issues/5
  6. [FIX]    example-app#39  Refactor session store     — Code Reviewer requested changes
              https://github.com/your-org/example-app/pull/39
  …
```

Markdown (`--markdown`, suitable for pasting into a TODO file):

```markdown
## Tasks — 2026-04-06

- [ ] **MERGE** example-app#41 — Add health endpoint (approved, CI green) — https://…
- [ ] **FIX-CI** example-app#42 — CSV export, lint job failed — https://…
- [ ] **REVIEW** billing-api#8 — Fix invoice rounding — https://…
- [ ] **TRIAGE** example-app#117 — Login fails on Safari (priority-high) — https://…
- [ ] **REPLY** marketing#5 — Hero copy refresh, designer commented — https://…
```

JSON (`--json`):

```json
[
  {
    "id": "example-app#41",
    "type": "MERGE",
    "score": 90,
    "title": "Add health endpoint",
    "url": "https://...",
    "project": "example-app",
    "reason": "approved + CI green"
  },
  ...
]
```

## Action types

| Type | Meaning |
|------|---------|
| `MERGE` | Approved + CI green — click merge |
| `FIX-CI` | Your PR has a failing check |
| `REVIEW` | A PR is waiting on your review |
| `FIX` | Your PR has changes requested |
| `TRIAGE` | An issue needs labelling, priority, or assignment |
| `REPLY` | A comment is waiting on your response |
| `WORK` | An issue assigned to you with no PR yet |
| `DECIDE` | A decision is blocking progress (`/decide` needed) |

## Filters

| Flag | Effect |
|------|--------|
| `--top N` | Only show the top N items |
| `--priority high` | Only critical and high priority |
| `--project <name>` | Limit to one project from the registry |
| `--type MERGE,REVIEW` | Comma-separated action types |
| `--markdown` | Markdown checklist output |
| `--json` | JSON output |

## Rules

1. **Always include the URL on every line** — the user needs to click
2. **One action per line** — don't bundle "review and merge" as one task
3. **Always sort by score, then staleness** — never alphabetical by default
4. **Multi-project aware** — iterate the registry, not the org
5. **Never modify anything** — read-only
6. **Skip resolved items** — if a PR is merged or an issue is closed mid-run, drop it
7. **Cap at 50 items by default** — if there are more, show count and suggest filters
8. **Prefer actionable over informational** — "11 PRs reviewed by others" is not a task

## Related skills

- `/inbox` — same data, grouped by category instead of flattened
- `/status` — current project state
- `/projects` — portfolio table

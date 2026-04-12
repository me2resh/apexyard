---
name: status
description: Snapshot of the current project — git state, open PRs with CI, recent merges, in-progress issue. Multi-project aware. Use to orient yourself in a fresh session.
allowed-tools: Bash, Read, Grep, Glob
---

# /status — Current Status Snapshot

A focused "where am I" view. Where `/inbox` shows what's waiting on you and `/projects` shows portfolio health, `/status` shows the **current state of work**: branch, dirty files, recent commits, open PRs, and the in-progress issue.

## Usage

```
/status
/status --project example-app
/status --verbose
```

## Scope

Iterates every project in `apexstack.projects.yaml` (the registry at the root of your ops repo), or a single project if `--project <name>` is passed.

## What it shows

### A. Git state (per project)

```bash
git rev-parse --abbrev-ref HEAD                # current branch
git status --porcelain                         # dirty files
git log --oneline -10                          # last 10 commits
git fetch origin --quiet                       # silently update remote refs
git rev-list --left-right --count origin/main...HEAD  # ahead/behind
```

Output:

```
Branch: feature/GH-42-csv-export
  ↑ 3 commits ahead of origin/main, ↓ 0 behind
  Dirty: 2 files (M src/export.ts, ?? tests/export.test.ts)

Recent commits:
  abc123  feat(#42): scaffold csv writer
  def456  test(#42): csv writer happy path
  9876ab  chore: bump tsconfig target
```

### B. Open PRs in this project

```bash
gh pr list --state open --json number,title,url,headRefName,statusCheckRollup,reviewDecision
```

For each PR, show:

```
#42  feat(#42): CSV export        🟡 review pending   ✅ CI green   https://…
#41  fix(#37): timezone bug       ✅ approved         ❌ CI failed  https://…
```

CI status maps:

- All checks `SUCCESS` → `✅ CI green`
- Any `FAILURE` → `❌ CI failed`
- Any `PENDING` → `🟡 CI pending`
- No checks → `— no CI`

### C. Recently merged PRs

```bash
gh pr list --state merged --limit 5 \
  --json number,title,mergedAt,author,url
```

```
Recently merged:
  #40  chore: bump deps          merged 2h ago by octocat   https://…
  #39  fix(#36): edge case       merged 1d ago by octocat   https://…
```

### D. In-progress issue

The "current" issue is the one whose number matches the current branch (`feature/GH-42-…` → issue #42):

```bash
ISSUE=$(git rev-parse --abbrev-ref HEAD | grep -oE 'GH-[0-9]+|[A-Z]+-[0-9]+' | head -1 | grep -oE '[0-9]+')
gh issue view $ISSUE --json number,title,state,assignees,labels,url
```

Show:

```
In progress: #42 — Add CSV export
  Assigned: @octocat
  Labels:   feature, priority-high
  State:    open
  URL:      https://…
```

If the branch doesn't carry an issue ID, say so and suggest:

```
No issue ID in the current branch name.
Convention: feature/GH-42-description (or APE-42, ENG-42, etc.)
```

### E. AgDR check

```bash
ls docs/agdr/ 2>/dev/null | tail -3
```

```
Recent AgDRs:
  AgDR-0007-csv-format-choice.md
  AgDR-0006-job-runner.md
```

### F. Workspace warnings

Surface anything unusual:

- Untracked critical files (`.env`, `*.pem`, `*.key`)
- Branch is `main`/`master` but has local commits (you should be on a feature branch)
- More than 20 dirty files (probably forgot to commit)
- Branch is more than 5 commits behind `origin/main` (rebase recommended)

## Portfolio output

Run sections A–D for each project in the registry. Use a per-project header:

```
═══════════════════════════════════════
PROJECT: example-app  (active)
═══════════════════════════════════════

Branch: main
  ↑ 0 ahead, ↓ 0 behind
  Dirty: 0 files

Open PRs: 2
  …

Recently merged: 3
  …

═══════════════════════════════════════
PROJECT: billing-api  (handover)
═══════════════════════════════════════
…
```

If a project's workspace isn't cloned locally, show GitHub data only and mark git sections as `(workspace not cloned)`.

## Verbose mode

`--verbose` adds:

- Full diff stats (`git diff --stat`)
- All open PRs (not just summary)
- All AgDRs from the last 30 days
- CI run history for the current branch

## Output format (one-project view with `--project <name>`)

```
STATUS — example-app — 2026-04-06 09:14
========================================

Git:
  Branch: feature/GH-42-csv-export
  ↑ 3 ahead · ↓ 0 behind · 2 dirty files

Open PRs (1):
  #42  feat(#42): CSV export    🟡 review pending  ✅ CI green   https://…

Recently merged (3):
  #41  fix(#37): timezone bug   merged 2h ago
  #40  chore: bump deps         merged 1d ago
  #39  feat(#35): jwt rotation  merged 2d ago

In progress: #42 — Add CSV export   priority-high   https://…

Recent AgDRs:
  AgDR-0007-csv-format-choice.md

Warnings:
  ⚠ 1 untracked .env.local file (don't commit it)
```

## Rules

1. **Read-only** — never modify state from this skill
2. **Always show branch + dirty count** — even if everything is clean
3. **Map branch → issue automatically** — saves the user from looking it up
4. **Don't print empty sections** — except git, which always appears
5. **Multi-project iterates the registry** — not "all repos in the org"
6. **Never fail noisily** — if `gh` is unavailable, show git data and a warning
7. **Always include warnings section if there are any** — silence on dirty `.env` is dangerous

## Related skills

- `/inbox` — what's waiting on you across projects
- `/tasks` — actionable TODOs with URLs
- `/projects` — portfolio table view

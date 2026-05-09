---
name: status
description: Snapshot of the current project — git state, open PRs with CI, recent merges, in-progress issue. Multi-project aware. Use to orient yourself in a fresh session.
allowed-tools: Bash, Read, Grep, Glob
---

# /status — Current Status Snapshot

A focused "where am I" view. Where `/inbox` shows what's waiting on you and `/projects` shows portfolio health, `/status` shows the **current state of work**: branch, dirty files, recent commits, open PRs, and the in-progress issue.

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
/status                       # full report (default)
/status --project example-app # full report scoped to one project
/status --verbose             # full report with extras
/status --briefing            # 4-line "where am I" briefing (slide 6)
/status -b                    # short form of --briefing
```

When `--briefing` (or `-b`) is passed, skip every other section and shell out to `.claude/skills/status/briefing.sh`. The full default `/status` output is unchanged for invocations without the flag.

## Scope

Iterates every project in `apexyard.projects.yaml` (the registry at the root of your ops repo), or a single project if `--project <name>` is passed.

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

## Briefing mode (`--briefing` / `-b`)

A compact 4-line "where am I" snapshot — workspace, ticket, branch, role. Designed to answer the orientation question in 2 seconds at the top of a session, instead of running 3 skills (`/projects`, `/inbox`, `/status`). This is the same output produced by `bin/apexyard status` (the CLI shim — see below), so the on-screen view in Claude Code and the shell view stay identical.

Output shape (me2resh/apexyard#182):

```
Active workspace:  example-app
Active ticket:     #42 — Add CSV export
Branch:            feature/GH-42-csv-export
Role set:          backend
```

Behaviour:

| Field | Source |
|-------|--------|
| Active workspace | cwd: `<ops_root>/workspace/<name>/...` → `<name>`; `<ops_root>` exactly → `(ops)`; anywhere else → `(unknown)` |
| Active ticket | `<ops_root>/.claude/session/tickets/<workspace>` first (only when workspace is a real name), then `<ops_root>/.claude/session/current-ticket`. Format: `#<number> — <title>`. No marker → `(none)` |
| Branch | `git branch --show-current`, run inside the inferred workspace dir (or cwd if no workspace). Detached HEAD or no git repo → `(no branch)` |
| Role set | Active ticket's labels — first match against the canonical list (`backend`, `frontend`, `qa`, `security`, `platform`, `sre`, `data`, `ux`, `ui`, `product`, `tech-lead`, plus the `-engineer` / `-auditor` / `-designer` / `-manager` / `-lead` long forms). No match (or no ticket) → `<none — inferred per task>` |

Implementation: the logic lives in `.claude/skills/status/briefing.sh` so it's testable in isolation and runnable from a plain shell (no Claude Code dependency). Smoke tests at `.claude/hooks/tests/test_status_briefing.sh`.

When invoked from inside Claude Code as `/status --briefing`, run the helper:

```bash
bash .claude/skills/status/briefing.sh
```

When invoked from a shell as `apexyard status`, the same helper runs via `bin/apexyard` (see § "CLI shim" below).

### Role inference scope

V1 ships **label-based inference only** — (a) on the trigger list in #182. The (b) recent-edits and (c) prompt-history strategies are explicit non-goals for v1; they land in a follow-up ticket if the basic version proves useful.

### CLI shim — `apexyard status`

`bin/apexyard` is a small bash script that exposes briefing mode at the shell:

```bash
# Install (one-time)
ln -s "$(pwd)/bin/apexyard" ~/.local/bin/apexyard

# Use from anywhere inside the fork or any workspace/<name>/ clone
apexyard status
```

The shim walks up from `$PWD` looking for the apexyard fork root (`onboarding.yaml` + `apexyard.projects.yaml`), then runs the same briefing helper. No PATH-shadowing of the `claude` binary, no recursion into Claude Code — pure `bash` end-to-end.

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

---
name: projects
description: List all managed projects with status, branch, open PRs, and open issue counts, portfolio-level view.
allowed-tools: Bash, Read, Grep, Glob
---

Writing: read docs/skills/shared/writing-rule.md before you write a durable artifact.

# /projects: List Managed Projects

Show every managed project with a one-line health summary. Read `apexyard.projects.yaml` at the ops-repo root (your apexyard fork). Iterate through its registry.

## Path resolution

Use `.claude/hooks/_lib-portfolio-paths.sh` to resolve paths. Read the registry through `portfolio_registry`, per-project docs through `portfolio_projects_dir`, and the ideas backlog through `portfolio_ideas_backlog`. Source the helper at the start of each bash block that uses these paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match the single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Split-portfolio adopters override `portfolio.{registry, projects_dir, ideas_backlog}` in `.claude/project-config.json`. Do not hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks. The helper resolves the adopter's mode. See `docs/multi-project.md`.

## Usage

```
/projects
/projects --status active
/projects --json
```

## Behaviour

Read `apexyard.projects.yaml`:

```yaml
version: 1
projects:
  - name: example-app
    repo: your-org/example-app
    workspace: workspace/example-app
    docs: projects/example-app
    status: active
    roles: [tech-lead, backend-engineer]
```

For each project, gather:

```bash
# If a local workspace clone exists, use it for git data
if [ -d "{workspace}" ]; then
  BRANCH=$(git -C {workspace} rev-parse --abbrev-ref HEAD)
  LAST=$(git -C {workspace} log -1 --format='%h %ar %s')
  DIRTY=$(git -C {workspace} status --porcelain | wc -l | tr -d ' ')
else
  BRANCH="(not cloned)"
  LAST="-"
  DIRTY="-"
fi

# Always go to GitHub for PRs / issues (project of record)
PRS=$(gh -R {repo} pr list --state open --json number --jq 'length')
ISSUES=$(gh -R {repo} issue list --state open --json number --jq 'length')
```

If `apexyard.projects.yaml` is absent from the ops-repo root, print a clear error. Direct the user to `apexyard.projects.yaml.example` and `docs/multi-project.md` for setup.

## Output format

A markdown table:

```markdown
| Project | Status | Branch | PRs | Issues | Last Commit | Dirty |
|---------|--------|--------|-----|--------|-------------|-------|
| example-app | active | main | 3 | 12 | 2h ago: fix(...) | 0 |
| billing-api | handover | feature/GH-4 | 1 | 8 | 1d ago: feat(...) | 2 |
| marketing-site | paused | main | 0 | 1 | 30d ago: chore(...) | 0 |
```

After the table, a summary line:

```
3 projects · 4 open PRs · 21 open issues · 1 dirty workspace
```

And, if relevant, flag rows that need attention:

```
⚠ marketing-site: last commit 30 days ago (paused or stale?)
⚠ billing-api: 2 uncommitted files in workspace
```

## Filters

| Flag | Effect |
|------|--------|
| `--status active` | Only show projects with `status: active` |
| `--status handover` | Only show projects mid-handover |
| `--status paused` | Only show paused projects |
| `--status archived` | Only show archived projects |
| `--json` | Emit machine-readable JSON instead of a table |

## Errors and edge cases

| Condition | Behaviour |
|-----------|-----------|
| No `apexyard.projects.yaml` at the ops-repo root | Print a clear error and a sample registry to copy |
| Project listed but workspace path missing | Show the row with `(not cloned)`. Do not fail |
| `gh` not authenticated | Show the row with `?` for PRs/issues. Do not fail |
| `repo` field looks invalid | Skip with a warning, continue with the rest |

## Rules

1. **Registry-driven**: the registry is the source of truth. Do not use discovery as a fallback.
2. **Source of truth for PRs/issues = GitHub**: never read from a stale local file
3. **Source of truth for branch state = local workspace**: `gh` does not know about dirty files.
4. **Do not silently fail on a missing project**: show the row and mark the gap.
5. **Sort by status then name**: active first, then handover, then paused, then archived
6. **Never modify the registry from this skill**: read-only

## Related skills

- `/inbox`: same registry, but filtered to "needs your attention"
- `/status`: per-project deep dive (current branch, recent commits)
- `/tasks`: actionable list with URLs
- `/handover`: onboard a new repo into the registry

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

---
name: handover
description: Onboard an external repo into ApexStack management by generating a structured handover assessment. Use when adopting a project that wasn't built under ApexStack.
argument-hint: "<project name> [path or url]"
allowed-tools: Bash, Read, Grep, Glob, Write
---

# /handover — External Repo Handover Assessment

Adopt an external repo into ApexStack management. The skill reads the target repo, synthesises a structured handover document, and tells you which ApexStack roles, workflows, and hooks should kick in.

This is the bridge between "we just inherited this codebase" and "this codebase is now governed by our normal SDLC".

## Usage

```
/handover legacy-billing-api
/handover legacy-billing-api ../legacy-billing-api
/handover marketing-site https://github.com/some-org/marketing-site
```

## Output location

The assessment is always written to:

```
projects/<name>/handover-assessment.md
```

The folder lives in the ops repo (your fork of apexstack), alongside the rest of `projects/`.

If `projects/<name>/` doesn't exist, create it. Also seed a `projects/<name>/README.md` stub if missing — see `projects/README.md` for the convention.

## Process

### 1. Locate the target repo

If a path is given, use it. If a URL is given, prompt the user to clone it into `workspace/<name>/` first (don't clone automatically — that's a side-effect with cost). If nothing is given, ask:

```
Where is the target repo? Local path or git URL?
```

### 2. Read the surface area

Without running anything destructive, gather:

```bash
# Tree (top 2 levels, prune node_modules / .git)
find <repo> -maxdepth 2 -type d \
  ! -path '*/node_modules*' \
  ! -path '*/.git*' \
  ! -path '*/dist*' \
  ! -path '*/build*'

# Key files
ls <repo>/README* <repo>/package.json <repo>/pyproject.toml \
   <repo>/Cargo.toml <repo>/go.mod <repo>/Gemfile 2>/dev/null

# CI config
ls <repo>/.github/workflows/ 2>/dev/null

# Last commit & contributors
git -C <repo> log -1 --format='%h %ai %an %s'
git -C <repo> shortlog -sn --no-merges | head -10

# Open issues / PRs (if it's a GitHub repo)
gh -R <owner/name> issue list --state open --json number,title,labels --limit 10
gh -R <owner/name> pr list --state open --json number,title --limit 10
```

### 3. Detect the tech stack

Look at:

- `package.json` → Node ecosystem; check `engines`, `scripts`, `dependencies`
- `pyproject.toml` / `requirements.txt` → Python
- `Cargo.toml` → Rust
- `go.mod` → Go
- `Gemfile` → Ruby
- `Dockerfile` → containerised; what base image?
- `.github/workflows/` → existing CI; how mature?
- `tsconfig.json` strictness, presence of tests, presence of linters

### 4. Try a build (optional, ask first)

```
Should I attempt to build the project to check current health? (y/n)
```

If yes and it's a Node project: `npm install --ignore-scripts && npm run build` (or whatever the package.json scripts say). Capture pass/fail and any errors.

### 5. Synthesise the assessment

Write `projects/<name>/handover-assessment.md`:

```markdown
# {name} — Handover Assessment

**Date**: YYYY-MM-DD
**Assessor**: {git user}
**Status**: handover

## Origin

- **Where it came from**: {acquisition / inherited team / open source / contractor / etc.}
- **Original owner**: {if known}
- **Repo location**: {URL or path}
- **First commit date**: {from git log}
- **Last commit date**: {from git log}

## Current State

### Tech stack
- Language: {…}
- Runtime: {…}
- Framework: {…}
- Database: {…}
- Test framework: {…}
- CI: {…}

### Build status
- `npm install`: {ok / failed}
- `npm run build`: {ok / failed / not attempted}
- `npm run test`: {ok / failed / not attempted}
- `npm run lint`: {ok / failed / not attempted}

### Test coverage
- Estimated: {…} (from coverage report if available, otherwise "unknown")

### Repo activity
- Commits in last 90 days: {…}
- Open issues: {…}
- Open PRs: {…}
- Top contributors: {…}

## Quality Risks

### Security
- {known CVEs in deps, hardcoded secrets, missing auth, etc.}

### Dependencies
- {abandoned packages, major versions behind, license issues}

### Technical debt
- {missing tests, no types, dead code, tangled architecture, etc.}

### Operational
- {missing CI, no monitoring, no deploy automation, etc.}

## Integration Plan

### Roles that apply
- {tech-lead, backend-engineer, frontend-engineer, sre, security-auditor, …}

### Workflows that kick in
- [ ] PR workflow (`.claude/rules/pr-workflow.md`) — every change goes through a PR
- [ ] AgDR for technical decisions
- [ ] Code Reviewer agent on every PR
- [ ] Security Reviewer agent on first pass and high-risk PRs
- [ ] `/audit-deps` on adoption and monthly thereafter

### Hooks to enable
- [ ] `block-git-add-all`
- [ ] `block-main-push`
- [ ] `validate-branch-name` (set `ticket_prefix` for this project's tracker)
- [ ] `validate-pr-create`
- [ ] `pre-push-gate`
- [ ] `check-secrets`

### CI templates to copy in
- [ ] `golden-paths/pipelines/ci.yml`
- [ ] `golden-paths/pipelines/security.yml`
- [ ] `golden-paths/pipelines/pr-title-check.yml`

### Registry entry
Multi-project is the default mode, so add this to `apexstack.projects.yaml` at the ops-repo root:

```yaml
- name: {name}
  repo: {owner/name}
  workspace: workspace/{name}
  docs: projects/{name}
  status: handover
  roles:
    - tech-lead
    - backend-engineer
```

## Next Steps

1. {first concrete action — usually "run /audit-deps and triage criticals"}
2. {second action — usually "open issues for each Quality Risk above"}
3. {third action — usually "merge the CI templates as the first PR under ApexStack"}
4. {…}

## Open Questions
- {anything you couldn't determine from a static read}
```

### 6. Return a summary

```
Handover assessment written: projects/{name}/handover-assessment.md

Tech stack: {one-liner}
Build: {ok / failed}
Risks: {N items}
Next steps: {first 2}

Recommended status in registry: handover
```

## Rules

1. **Read-only by default** — never modify the target repo without explicit permission.
2. **Honest assessment** — if a build fails, say so. Don't paper over problems.
3. **Always seed `projects/<name>/`** — even if minimal.
4. **Always include the registry snippet** — multi-project is the default, so the user almost certainly wants the registry entry right away.
5. **Never auto-clone** — ask for the path.
6. **Never store secrets** — if `.env` is found, list its presence but never read its contents.
7. **Status starts at `handover`** — moves to `active` only after the integration plan is executed.

## When to use this

| Trigger | Use `/handover`? |
|---------|------------------|
| Inherited a codebase from another team | Yes |
| Acquired a company's repo | Yes |
| Adopted an open-source project as a dependency | No — that's `/audit-deps` |
| Forked an internal tool you wrote yesterday | No — it's already yours |
| Importing a side project into the org | Yes |

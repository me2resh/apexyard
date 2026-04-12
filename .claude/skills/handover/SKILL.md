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

The entry that will be appended to `apexstack.projects.yaml` at the root of the ops repo (see step 6 — the skill does this append for you, with confirmation):

```yaml
- name: {name}
  repo: {owner/name}
  workspace: workspace/{name}
  docs: projects/{name}
  status: handover
  roles:
    {dynamically derived from the tech stack + CI config — see
     "Deriving applicable roles" below}
```

**Deriving applicable roles**: don't hard-code `[tech-lead, backend-engineer]`. Look at the tech stack from step 3:

| Signal | Add role |
|--------|----------|
| Any backend code (package.json with server deps, pyproject.toml, etc.) | `backend-engineer` |
| Any UI code (React/Vue/Svelte, `src/components/`, CSS modules) | `frontend-engineer` |
| CI config detected (`.github/workflows/`, `.gitlab-ci.yml`, etc.) | `platform-engineer` |
| Production deployment evidence (Dockerfile, Terraform, AWS/GCP/Azure SDK) | `sre` |
| Auth / crypto / secrets in the diff | `security-auditor` |
| Always | `tech-lead` |

For a typical handover you'll end up with 3-5 roles in the list.

## Next Steps

Derived dynamically from the Quality Risks found in this assessment. Don't emit generic placeholders — emit specific actions.

Mapping table:

| Risk found | Next step entry |
|------------|-----------------|
| ≥ 1 CVE in deps (any severity) | `1. /audit-deps {name} — triage the {severity} {package} CVE before any new feature work` |
| Failing tests | `2. Fix the {N} failing tests in {module} before merging new PRs (baseline must be green)` |
| No observability (no Sentry/Datadog/CloudWatch/etc.) | `3. /decide on observability ({two most common options for this stack})` |
| Stale CI (no runs in > 30 days) | `4. Re-enable CI on this repo — copy in golden-paths/pipelines/ci.yml` |
| Test coverage unknown | `5. Set up test coverage reporting (vitest/jest coverage config) before the first feature` |
| ≥ 10 open issues | `6. Triage the issue backlog with the previous owner before taking ownership` |
| Missing README or onboarding doc | `7. Write a minimum-viable README (what the project does, how to run it locally, where it deploys)` |

If no risks match a row, omit that row. If fewer than 3 actions come out, add:

- `{next} /code-review the most-recent PR on this repo as Rex to calibrate review standards`
- `{next} Stakeholder sync with the previous owner to cover context the static read couldn't surface`

## Post-Handover Checklist

Also derived from the risks found. Tailor to the specific repo — don't emit generic items.

- [ ] Review this assessment with the previous owner
- [ ] {top quality risk} — close before the first feature PR
- [ ] {second quality risk} — scheduled in the first 2 weeks
- [ ] Add `{name}` to the weekly `/stakeholder-update` rollup
- [ ] Onboard the roles listed above into the team's on-call / review rotation
- [ ] Set up a test coverage baseline (run `npm test -- --coverage` or equivalent and commit the threshold)
- [ ] Run `/audit-deps {name}` monthly for the next 3 months

## Open Questions

- {anything you couldn't determine from a static read}

```

### 6. Append to the portfolio registry

**Don't just print the snippet** — offer to append it automatically:

```

Ready to add {name} to apexstack.projects.yaml? (y/n)
> y

```

If yes:

1. **Locate the registry**: `apexstack.projects.yaml` at the root of the ops repo. If missing, first copy from `apexstack.projects.yaml.example` and show the user a warning: `⚠ Registry didn't exist — created from .example. You may need to fill in other projects.`

2. **Append the entry**. Use `yq` if available for a safe YAML edit, otherwise append as plain text with careful indentation:

   ```bash
   # Prefer yq for correctness
   if command -v yq >/dev/null 2>&1; then
     yq eval -i '.projects += [{"name": "{name}", "repo": "{owner/name}", "workspace": "workspace/{name}", "docs": "projects/{name}", "status": "handover", "roles": [{roles}]}]' apexstack.projects.yaml
   else
     # Fallback: plain text append
     cat >> apexstack.projects.yaml <<'YAML'
     - name: {name}
       repo: {owner/name}
       workspace: workspace/{name}
       docs: projects/{name}
       status: handover
       roles:
         - tech-lead
         - backend-engineer
   YAML
   fi
   ```

3. **Validate the result**:

   ```bash
   # Prefer yq or python -c 'import yaml; yaml.safe_load(open("apexstack.projects.yaml"))'
   yq eval '.' apexstack.projects.yaml >/dev/null 2>&1 \
     || python3 -c 'import sys, yaml; yaml.safe_load(open("apexstack.projects.yaml"))' 2>&1
   ```

   If validation fails: **restore the previous version** from a backup made before the write, print the parse error, and tell the user to fix it manually. Never leave the registry in a broken state.

4. **Confirm to the user**:

   ```
   ✓ Added {name} to apexstack.projects.yaml
     status: handover
     roles: {the derived list}
   ```

If the user says `n` at the prompt, print the snippet they'd need to copy manually and continue to step 7 without writing anything:

```
Skipping the auto-append. If you want to add it later, copy this into apexstack.projects.yaml:

  - name: {name}
    repo: {owner/name}
    workspace: workspace/{name}
    docs: projects/{name}
    status: handover
    roles: {derived list}
```

### 7. Return a summary

```
Handover assessment written: projects/{name}/handover-assessment.md
Registry updated: apexstack.projects.yaml ({added | skipped})

Tech stack: {one-liner}
Build: {ok / failed}
Risks: {N items} ({highest severity})
Roles activated: {comma-separated}
Top 3 next steps:
  1. {first dynamic step}
  2. {second dynamic step}
  3. {third dynamic step}
```

## Rules

1. **Read-only against the target repo** — never modify the target repo without explicit permission. (The ops repo IS modified — you append to the registry and create the assessment file — but that's the point.)
2. **Honest assessment** — if a build fails, say so. Don't paper over problems.
3. **Always seed `projects/<name>/`** — even if minimal.
4. **Auto-append to the registry** (with confirmation) — don't leave the user to copy-paste a snippet. Propose the append, validate the resulting YAML, roll back on failure.
5. **Derive roles from the stack** — don't hard-code `[tech-lead, backend-engineer]`. The roles list depends on the actual tech stack, CI config, and security surface detected in step 3.
6. **Derive next steps from the risks** — don't emit generic placeholders. Every "Next Step" must correspond to a specific finding from the Quality Risks section of the assessment.
7. **Never auto-clone** — ask for the path.
8. **Never store secrets** — if `.env` is found, list its presence but never read its contents.
9. **Status starts at `handover`** — moves to `active` only after the integration plan is executed.
10. **Never break the registry** — if the YAML append breaks the file, restore the previous version and ask the user to edit manually.

## When to use this

| Trigger | Use `/handover`? |
|---------|------------------|
| Inherited a codebase from another team | Yes |
| Acquired a company's repo | Yes |
| Adopted an open-source project as a dependency | No — that's `/audit-deps` |
| Forked an internal tool you wrote yesterday | No — it's already yours |
| Importing a side project into the org | Yes |

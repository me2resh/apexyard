---
name: onboard
description: First-run discovery pass for a new ApexStack repo. Asks the questions a Chief-of-Staff / engineering lead would ask on day one — project identity, tracker repo, required CI checks, reviewers, UI/backend, deploy targets, sensitive topics — and writes the onboarding marker plus a machine-readable project-config.json so other hooks and skills stop assuming defaults.
disable-model-invocation: false
argument-hint: ""
effort: medium
---

# /onboard - ApexStack Discovery Pass

Same principle as `.claude/rules/role-triggers.md`: do not start work until you know who, what, why, and under which constraints. Run this skill the **first time** you open a new repo under the ApexStack harness. It's idempotent — running it again updates the config.

## When This Runs

The `onboarding-check.sh` SessionStart hook flags missing onboarding at the top of every session. Invoke `/onboard` as the first action in a new repo, or any time the answers materially change (e.g., a new CI check was added, a reviewer rotated, deploy target moved).

## Process

Ask the questions **one at a time**, not all at once. Wait for each answer before moving on. If the answer is obvious from the repo (e.g., project name = directory name, code repo = `git remote get-url origin`), **propose the default and ask for confirmation** rather than making the user type it.

### Q1: Project Identity

```
What is this project and what does it do? (one sentence)
```

Then: `What GitHub repo holds its code?` — default to the current `git remote get-url origin` when available.

### Q2: Ticket Tracker

```
Where do tickets for this project live? (owner/repo for GitHub Issues)
```

Default to the code repo unless the user says otherwise. Exceptions (e.g., framework repos whose tickets live in a separate ops repo) must be stated explicitly.

### Q3: Required CI Checks

```
What must pass locally before `git push`? List commands, grouped by sub-project if this is a monorepo.
```

Typical answers (adapt to stack):

- TypeScript / Node: `npm run lint && npm run typecheck && npm run test && npm run build`
- AWS SAM backend: add `sam validate --lint`
- Terraform: `terraform fmt -check && terraform validate`
- Swift / SPM: `swift build && swift test`
- Python: `ruff check && mypy && pytest`

Capture per sub-project if monorepo; the `pre-push-gate.sh` hook will later reference these.

### Q4: Reviewers

```
Who reviews PRs for this repo?
```

Default: **Rex (code-reviewer agent) + one human approver** (Tech Lead / Project owner / CEO, depending on the team). Note any extras — `Shield` (security-reviewer) for auth/crypto code, domain expert for specialised areas, UI Designer for UI-heavy PRs.

### Q5: UI Work

```
Does this repo ship user-facing UI?
```

If yes: any PR touching `.tsx|.jsx|.vue|.svelte|.css|.scss` should go through the `/frontend-design` skill before implementation, and merge requires a design review per `workflows/code-review.md`.

### Q6: Deploy Targets

```
What environments does this repo deploy to and where are the URLs?
```

Capture staging + prod URLs, any env-var names for secrets (never the values), and whether deploys are automatic (on merge) or manual.

### Q7: Sensitive Topics

```
Is there any info that must NEVER be committed or put in GitHub Issues?
```

Common: cloud account IDs, DB connection strings, pool / tenant IDs, internal dashboard URLs, customer names. Record these as "memory-only" topics — they go into the user's auto-memory, never into git.

## Write the Config

Create `.claude/project-config.json` (overwrite if exists):

```json
{
  "project": "<name>",
  "description": "<one-sentence>",
  "code_repo": "<owner/repo>",
  "tracker_repo": "<owner/repo>",
  "required_checks": {
    "<sub-project>": ["<command>", "..."]
  },
  "reviewers": ["rex", "<human-approver>"],
  "has_ui": true,
  "deploy": {
    "staging": "<url>",
    "prod": "<url>",
    "mode": "auto-on-merge | manual"
  },
  "sensitive_topics": ["..."],
  "onboarded_at": "<ISO-8601>",
  "onboarded_by": "<agent-or-user>"
}
```

Then: `touch .claude/session/onboarded` so the SessionStart hook stops flagging.

## Confirm to the User

Print a short summary of what was captured and where it's stored. Offer to save any sensitive-topic answers into the memory system (never into git, never into the project-config).

## Rules

1. **One question at a time** — avoid a wall of questions.
2. **Propose defaults** — read the repo to guess, then ask the user to confirm / override.
3. **Never commit the config automatically** — `.claude/project-config.json` is gitignored by default so sensitive deploy URLs and topic lists do not leak.
4. **Sensitive data → memory, never git** — cloud account IDs, secrets, and credentials belong in the user's auto-memory system, never in the config or issues.
5. **Re-run anytime** — the skill is idempotent. CI commands change, people rotate, deploys move; re-run and let it overwrite.

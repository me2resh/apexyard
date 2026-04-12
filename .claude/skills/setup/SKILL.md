---
name: setup
description: First-run framework bootstrap for a new ApexStack fork. Three exchanges — "describe your stack", "here are the defaults", "accept or customize?" — and the fork is configured. Run once after forking; re-run anytime to update.
disable-model-invocation: false
argument-hint: "[--reset]"
effort: medium
---

# /setup — ApexStack First-Run Bootstrap

Configures `onboarding.yaml` for a new ApexStack fork in three exchanges instead of eight sequential questions. The "describe, propose, confirm" pattern gets most users from fork to working in under 2 minutes.

## When this runs

The `onboarding-check.sh` SessionStart hook detects that `onboarding.yaml` still has placeholder values (e.g. `company.name: "Your Company Name"`) and prompts the user to run `/setup`. After `/setup` fills in real values and commits, the hook goes silent forever — even on fresh clones, because `onboarding.yaml` is committed.

Re-running `/setup` on an already-configured fork shows the current config and asks what to update. Use `--reset` to clear everything and start from scratch.

## Process

### Step 1: Check current state

Read `onboarding.yaml`. Two modes:

- **First run** (placeholder values detected): proceed to Step 2.
- **Already configured** (real values): show a summary of the current config and ask "What would you like to update?" — then jump to the specific section. Don't re-ask everything.
- **`--reset` flag**: clear `onboarding.yaml` back to the template defaults (copy from the upstream example or regenerate) and proceed as first run.

Detection: `grep -q '"Your Company Name"' onboarding.yaml` — if found, it's still a template.

### Step 2: One question — describe your world

Ask a single open-ended question:

```
Tell me about your company and tech stack in a few sentences.
For example: "We're a 3-person startup building a property management
SaaS. TypeScript + React frontend, AWS SAM backend with DynamoDB.
GitHub Issues for tracking, 1-week sprints."
```

**Do NOT ask sequential questions.** The whole point of this skill is to collapse the discovery into one natural-language exchange. The user describes their world; you parse it.

### Step 3: Parse and map to defaults

From the user's description, extract:

| Field | Parse from | Default if not mentioned |
|-------|-----------|------------------------|
| `company.name` | Company name in the description | Ask explicitly — this one's required |
| `company.mission` | What they're building | `""` (leave blank, user fills later) |
| `tech_stack.language` | "TypeScript", "Python", "Go", etc. | `"TypeScript"` |
| `tech_stack.framework` | "React", "Vue", "Svelte", etc. | `""` (no frontend) |
| `tech_stack.backend` | "Express", "FastAPI", "SAM", etc. | Inferred from language |
| `tech_stack.database` | "PostgreSQL", "DynamoDB", "MongoDB", etc. | `""` |
| `tech_stack.hosting` | "AWS", "GCP", "Azure", "Vercel", etc. | `"AWS"` |
| `project_management.tool` | "GitHub Issues", "Linear", "Jira" | `"GitHub Issues"` |
| `quality.required_checks` | Inferred from stack | `[lint, typecheck, test, build]` |
| `team` | Team size / roles mentioned | Minimal default (1 tech lead) |

Also infer non-obvious settings:

- If they mention "SAM" → `tech_stack.iac: "AWS SAM"` and add `sam validate --lint` to implied checks
- If they mention "Terraform" → `tech_stack.iac: "Terraform"` and add `terraform validate`
- If they mention "no frontend" or don't mention a framework → `workflows.require_design_review: false` (no UI = no design gate)
- If they mention "solo" or "1 person" → simplify team to just them, `required_reviews: 0`

### Step 4: Present the proposed config

Show a clean summary (NOT raw YAML — a formatted table or bulleted list):

```
Based on your description, here's how I'd configure your fork:

Company: ApexScript
Stack: TypeScript + React (frontend), AWS SAM + DynamoDB (backend)
Hosting: AWS
CI checks: npm run lint, npm run typecheck, npm run test, npm run build, sam validate --lint
Tracker: GitHub Issues, 1-week sprints
Reviewers: Rex (code-reviewer agent) + you
Quality: 80% coverage target, thorough review style
Team: 1 tech lead (you)

Design review gate: ON (React = UI work)
AgDR gate: ON (default architecture paths)
Commit types: framework defaults (feat, fix, refactor, test, docs, chore, style, perf, build, ci, revert)

Use these defaults, or customize?
```

### Step 5: Confirm or customize

- **"yes" / "looks good" / "use defaults"** → proceed to Step 6.
- **"customize X"** → ask about the specific field, update, re-show the summary with the change highlighted, re-confirm.
- **"no, actually we use Y"** → re-parse, re-propose.

Don't loop more than twice. If the user keeps correcting, switch to "tell me exactly what to change" direct-edit mode.

### Step 6: Write onboarding.yaml

Read the current `onboarding.yaml` template, replace placeholder values with the confirmed config, and write back. Preserve the file's structure and comments — the comments are documentation for future readers.

**Important:** use `Edit` tool to modify in-place, not `Write` to overwrite — this preserves comments and structure that the user didn't touch.

After writing:

```bash
git add onboarding.yaml
```

Stage but do NOT commit — let the user review the diff and commit when ready. Tell them:

```
onboarding.yaml updated and staged. Review with `git diff --cached` and
commit when you're happy: git commit -m "chore: configure apexstack for <company>"
```

### Step 7: Optionally seed the project registry

If the user mentioned a specific project in their description, offer to add it:

```
You mentioned a property management SaaS. Want me to register it as
your first managed project in apexstack.projects.yaml?
I'll need: repo name (owner/repo) and a short project name.
```

If yes → append to `apexstack.projects.yaml`, stage alongside `onboarding.yaml`.
If no → skip. They can add projects later with `/handover`.

## Rules

1. **One question to start.** Do not ask about company, then stack, then team, then tools separately. One open-ended prompt, one natural-language response, one proposed config.
2. **Propose, don't interrogate.** Show the full config with sensible defaults and let the user correct. Most fields have obvious defaults from the description.
3. **Stage, don't commit.** The user should see the diff before it's committed. `/setup` stages; the user commits.
4. **Preserve structure.** `onboarding.yaml` has comments that explain each section. Don't blow them away — edit in place.
5. **Idempotent.** Running `/setup` again shows current config and asks what to update. Running with `--reset` clears and re-asks.
6. **No project-config.json.** `/setup` configures the FRAMEWORK (onboarding.yaml). Per-project config is handled by `/handover` and `/idea` when projects enter the portfolio.

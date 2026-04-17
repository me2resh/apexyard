# Container Diagram — ApexStack

> **C4 Level 2** — the functional subsystems inside the ApexStack fork. Non-traditional: ApexStack has no runtime of its own. Each "container" is a folder-scoped set of files interpreted by an external system (Claude Code CLI, the user, or GitHub's rendering).

## Diagram

```mermaid
C4Container
    title Container Diagram for ApexStack

    Person(ops, "CEO / CoS / Tech Lead")
    System_Ext(claude, "Claude Code CLI")
    System_Ext(github, "GitHub")

    System_Boundary(apex, "ApexStack (ops fork)") {
        Container(claudemd, "CLAUDE.md", "Markdown", "Entry point. Claude Code reads this first. Imports rules and role-triggers.")
        Container(rules, ".claude/rules/", "Markdown", "Modular rule files — git conventions, ticket vocabulary, PR workflow, AgDR, PR quality, role triggers, workflow gates, code standards.")
        Container(hooks, ".claude/hooks/", "Shell scripts", "Mechanical enforcement — merge gates, ticket-first, secrets check, commit format, drift banner. Runs on PreToolUse / PostToolUse / SessionStart events.")
        Container(skills, ".claude/skills/", "Markdown SKILL.md files", "Slash commands — /setup, /handover, /update, /status, /inbox, /approve-merge, /approve-design, /decide, /code-review, etc. (31 skills)")
        Container(agents, ".claude/agents/", "Markdown agent defs", "Sub-agent definitions — code-reviewer (Rex), security-reviewer (Shield), dependency-auditor, pr-manager, ticket-manager.")
        Container(roles, "roles/", "Markdown role files", "19 role definitions across engineering / product / design / security / data. Activated by role-triggers.md matcher rules.")
        Container(workflows, "workflows/", "Markdown process docs", "SDLC, code review, deployment — the prose contract for how work moves.")
        Container(registry, "apexstack.projects.yaml", "YAML", "Portfolio registry. Lists every managed project. Skills iterate this to aggregate across projects.")
        Container(onboarding, "onboarding.yaml", "YAML", "Per-fork configuration — company, team, tech stack, quality bar.")
        Container(projectdocs, "projects/", "Per-project Markdown", "ApexStack docs about each managed project — handover assessments, per-project roadmaps, stakeholder updates.")
        Container(goldens, "golden-paths/", "YAML + Markdown", "Reusable GitHub Actions workflow templates — CI, security, dependency audit, PR title check, review check.")
    }

    Rel(ops, claudemd, "Reads / edits", "via Claude Code or editor")
    Rel(claude, claudemd, "Loads on session start")
    Rel(claudemd, rules, "Imports via @.claude/rules/*.md")
    Rel(claude, hooks, "Executes on tool events", "bash")
    Rel(claude, skills, "Invokes on /slash-command", "Skill tool")
    Rel(claude, agents, "Spawns sub-agents", "Agent tool")
    Rel(hooks, github, "Calls gh CLI", "gh pr / gh issue")
    Rel(skills, github, "Calls gh CLI", "gh pr / gh issue / gh api")
    Rel(skills, registry, "Reads for portfolio iteration")
    Rel(skills, projectdocs, "Reads / writes per-project docs")
    Rel(hooks, onboarding, "SessionStart config check")
    Rel(workflows, roles, "References role files at phase boundaries")
```

## How to read this

ApexStack is unusual in C4 terms: there is **no running process that IS ApexStack**. Every "container" above is a folder of files. The "runtime" is either:

- **Claude Code CLI** — reads `CLAUDE.md`, executes hooks, invokes skills, spawns sub-agents
- **The user** — reads role files, workflow docs, and the portfolio registry manually
- **GitHub** — renders Markdown in the repo view, enforces branch protection, runs CI on `golden-paths/` pipelines copied into project repos

The diagram captures which "container" does what *when interpreted by the right runtime*. It's a useful zoom level even though it diverges from the typical "containers are deployable units" framing of L2.

## Key relationships

- **CLAUDE.md → rules** is the single most important arrow. Every rule file is imported via `@.claude/rules/*.md` from `CLAUDE.md`, and Claude Code applies them. Without that import chain, rules are orphaned prose.
- **hooks → github** — hooks call `gh` directly (e.g. `block-merge-on-red-ci.sh` runs `gh pr checks`). This is how ApexStack's mechanical enforcement reaches the remote tracker state.
- **skills → github** — skills are the user-facing portfolio-aware commands. Most call `gh` at some point; some also read the registry to iterate.
- **skills → registry / projectdocs** — the portfolio-level read/write flow. `/inbox` / `/status` / `/projects` / `/stakeholder-update` all live here.

## What this diagram does NOT show

- Specific hook-to-rule mapping (which hook enforces which rule) — see `docs/rule-audit.md` for that.
- The full list of 31 skills — see CLAUDE.md § "Available skills".
- The full list of 19 roles — see `.claude/rules/role-triggers.md`.
- The user's local `workspace/<name>/` clones of managed projects — they're gitignored and sit outside the ApexStack boundary (they belong to the managed project, not to ApexStack).

## Related diagrams

- L1 system context: [`apexstack-context.md`](./apexstack-context.md)
- SDLC sequence (how a feature flows phase by phase): `workflows/sdlc.md`
- Rule audit (every MUST → hook / advisory / deferred): `docs/rule-audit.md`

## Maintenance

Updates when:

- A new top-level directory is added or removed (e.g. if `.claude/skills/` were renamed)
- A new "container" type joins the architecture (e.g. a `templates/` folder were promoted to first-class)
- The Claude Code integration model changes (new event type, new agent shape)

Skill-count / hook-count / role-count drift goes in the relevant summary docs (CLAUDE.md, hooks/README.md), not here. This diagram stays at the "shape of the fork" level.

# System Context — ApexStack

> **C4 Level 1** — how ApexStack fits into the day of a CEO / Chief-of-Staff / Tech Lead managing a portfolio of projects.

## Diagram

```mermaid
C4Context
    title System Context for ApexStack

    Person(ops, "CEO / Chief of Staff / Tech Lead", "Solo operator running a portfolio of projects. The 'user' of ApexStack.")
    Person(contributor, "Contributor", "Framework author pushing upstream changes. Usually the same human as the ops role, but a distinct hat.")

    System(apex, "ApexStack (fork)", "Governance, workflow, and SDLC primitives for a managed project portfolio. Lives as a GitHub fork in the user's org; clone is the ops repo.")

    System_Ext(claude, "Claude Code CLI", "The execution environment. Reads CLAUDE.md, runs hooks, invokes skills, spawns sub-agents. Without Claude Code, ApexStack is just markdown.")
    System_Ext(github, "GitHub", "Hosts the ops fork, hosts every managed project, hosts all issue trackers. Merge gates, CI, PR reviews all live here.")
    System_Ext(projects, "Managed Projects", "The N repos under the ops repo's registry. Each has its own GitHub repo, its own issues, its own CI. ApexStack governs them; it does not host them.")
    System_Ext(upstream, "me2resh/apexstack (upstream)", "The canonical ApexStack framework. The ops fork pulls from here periodically via /update.")

    Rel(ops, apex, "Uses daily", "gh + Claude Code")
    Rel(ops, claude, "Invokes", "terminal")
    Rel(claude, apex, "Reads CLAUDE.md, runs hooks, invokes skills")
    Rel(apex, github, "Reads issues, opens PRs, posts reviews, merges", "gh CLI")
    Rel(apex, projects, "Governs via the registry (apexstack.projects.yaml)")
    Rel(contributor, upstream, "Contributes back to", "PRs")
    Rel(apex, upstream, "Syncs from periodically", "/update skill")
```

## How to read this

- **The user is the ops role.** Whoever runs Claude Code in the ops fork. In a solo setup that's one person wearing many hats; in a team setup it's a small group.
- **ApexStack itself is a collection of docs, hooks, skills, and registries** — it doesn't "run" anywhere standalone. It's interpreted by Claude Code. Everything ApexStack enforces, it enforces through Claude Code hooks or through human-read rules in CLAUDE.md.
- **GitHub is the source of truth** for tracker state, PR state, merge state. ApexStack never holds state that should live in GitHub — the approval markers in `.claude/session/reviews/` are session-local and gitignored.
- **Managed projects are first-class external systems.** ApexStack does not ingest their code; it points at them via the registry. Their own git history, CI, and issues stay in their own repos.

## Why these relationships matter

- `ops → apex` **via Claude Code** — the user never edits ApexStack files through some proprietary UI; they use the CLI, which means shell tooling, git, and gh remain the authoritative interface.
- `apex → github` — the single integration point. No Jira, no Linear, no Notion. If you want ApexStack to feel different, the work lives in adding GitHub integrations, not in replacing GitHub.
- `apex → upstream` **via /update** — the fork-sync path. Without `/update`, forks silently drift (PRD-0002 problem #1). The SessionStart drift banner ensures the user knows when to invoke it.

## What this diagram does NOT show

- Internal structure of ApexStack (hooks, skills, agents, rules, workflows) — that's the L2 container diagram in `apexstack-container.md`.
- Deployment topology — ApexStack doesn't "deploy." It lives in the user's local clone and on GitHub.
- The flow of a specific feature from idea to production — that's the SDLC, documented in `workflows/sdlc.md` as a sequence, not a context diagram.

## Maintenance

Should change only when a major new external dependency enters or leaves. Candidates:

- If ApexStack ever gains a first-class Linear / Jira integration → add those as external systems
- If the managed-project model is replaced or extended (unlikely) → re-draw the boundary
- If upstream naming / sync model changes — edit accordingly

Target: no more than one or two updates per year.

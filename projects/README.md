# `projects/` — ApexStack Per-Project Docs

This directory holds **ApexStack-managed documentation** for each project ApexStack governs. It's the home for docs that:

- Span multiple commits or live above the repo level
- Belong to the operating model rather than the codebase
- Need to exist before the project even has its own repo (e.g. handover assessments)

In **multi-project mode** (the default), this directory is the canonical place for per-project ApexStack docs in the ops repo. In **single-project mode** (opt-in), this directory is optional — you can keep your roadmap, ideas, and notes at the project root instead.

## Layout

Each managed project gets its own subdirectory:

```
projects/
├── README.md                       ← you are here
├── ideas-backlog.md                ← shared ideas backlog (multi-project mode)
│
├── example-app/
│   ├── README.md                   ← project overview, owners, links
│   ├── roadmap.md                  ← project-specific roadmap
│   ├── handover-assessment.md      ← if onboarded via /handover
│   ├── updates/
│   │   ├── weekly-2026-04-06.md
│   │   ├── weekly-2026-03-30.md
│   │   └── monthly-2026-03.md
│   └── notes/
│       ├── architecture.md
│       └── ops-runbook.md
│
├── billing-api/
│   ├── README.md
│   ├── roadmap.md
│   └── handover-assessment.md
│
└── marketing-site/
    ├── README.md
    └── roadmap.md
```

## What goes here vs. inside the project's own repo

Use the **"would I want this to follow the code if the project was spun out?"** test:

| Doc | Goes in `projects/<name>/` (ops repo) | Goes in the project's own repo |
|-----|---------------------------------------|-------------------------------|
| Project README (overview, owners, links) | ✅ for an at-a-glance ops view | ✅ also keep in project repo |
| Roadmap | ✅ if it spans cycles and stakeholders | Optional — duplicate if useful |
| Handover assessment | ✅ always — it's a one-time onboarding artefact | ❌ |
| Stakeholder updates | ✅ — they're an ops record, not a code artefact | ❌ |
| Ops runbooks | ✅ — incident playbooks live with the operator | ✅ if engineering needs them too |
| ADRs (architectural decisions) | ❌ | ✅ — they're tied to commits |
| AgDRs (agent decisions) | ❌ | ✅ — they're tied to commits |
| READMEs for the codebase | ❌ | ✅ |
| API docs | ❌ | ✅ |
| Strategic context, market positioning | ✅ | ❌ |

## Per-project README convention

Every `projects/<name>/README.md` should answer:

```markdown
# {Project Name}

**Repo**: https://github.com/your-org/{name}
**Workspace**: workspace/{name}/
**Status**: active | handover | paused | archived
**Tier**: P0 | P1 | P2 (how strategic is it?)

## What it is
{One paragraph: what does this project do?}

## Who owns it
- **Tech Lead**: @username
- **Product**: @username
- **Stakeholders**: @username, @username

## Tech stack
{One line per layer: language, framework, db, hosting}

## Key links
- Production: https://...
- Staging: https://...
- Monitoring: https://...
- Runbook: ./notes/ops-runbook.md
- Roadmap: ./roadmap.md

## Recent activity
- Last release: ...
- Active milestones: ...
```

## When to create a new project folder

| Trigger | Action |
|---------|--------|
| New repo built from scratch under ApexStack | Create `projects/<name>/` with a README and (optionally) a roadmap |
| External repo onboarded via `/handover` | The skill creates the folder and the assessment for you |
| Project paused | Don't delete the folder — flip `status: paused` in the registry and the README |
| Project archived | Move to `projects/_archive/<name>/` and update the registry |

## Single-project mode

In single-project mode, this directory typically isn't used. Your project's docs live at the **root of the project repo**:

```
your-app/
├── ROADMAP.md
├── IDEAS.md
├── docs/
│   └── agdr/
└── ...
```

You only need `projects/` when you flip to multi-project mode and want a clean separation between project code and ops-level docs.

## Skills that read or write here

| Skill | Behaviour |
|-------|-----------|
| `/handover` | Creates `projects/<name>/handover-assessment.md` and seeds the README |
| `/roadmap` | Reads/writes `projects/<name>/roadmap.md` (multi-project) or `ROADMAP.md` (single) |
| `/idea` | Appends to `projects/ideas-backlog.md` (multi) or `IDEAS.md` (single) |
| `/stakeholder-update` | Writes to `projects/<name>/updates/` (multi) or `updates/` (single) |
| `/projects` | Reads each project README for the table view |
| `/status` | Reads roadmap and updates folder for context |

## Conventions

1. **Folder name = project name = registry name** — they must all match
2. **Lowercase, kebab-case** for folder names (`example-app`, not `ExampleApp`)
3. **Always include a README** — even if minimal
4. **Don't store secrets** — credentials belong in a secret manager, never in `projects/`
5. **Don't store generated artefacts** — no built bundles, no node_modules, no logs

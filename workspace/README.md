# `workspace/` — Live Project Clones

This directory holds **live working copies** of projects that ApexStack manages. It's where code work happens: branches, commits, PRs, CI. Everything under `workspace/*/` is gitignored — each managed project has its own remote and is cloned into this folder independently.

## How it works

1. Your ops repo is a fork of `me2resh/apexstack` (see [`docs/multi-project.md`](../docs/multi-project.md) for the full setup)
2. `apexstack.projects.yaml` at the root of your fork lists every project under management
3. For each project you want a local working copy of, `git clone` it into `workspace/<name>/` — the name should match the registry entry
4. ApexStack skills that need local git data (e.g. `/status` showing dirty files) will look here

## Directory layout

```
your-org/apexstack/                ← your fork of apexstack, cloned locally (the "ops repo")
├── .claude/                       ← shared rules, skills, hooks
├── apexstack.projects.yaml        ← the registry (which projects ApexStack manages)
├── onboarding.yaml                ← company, team, tech stack
│
├── workspace/                     ← LIVE WORKING COPIES (this directory)
│   ├── README.md                  ← you are here
│   ├── example-app/               ← `git clone github.com/your-org/example-app`
│   ├── billing-api/               ← `git clone github.com/your-org/billing-api`
│   └── marketing-site/            ← `git clone github.com/your-org/marketing-site`
│
├── projects/                      ← APEXSTACK DOCS PER PROJECT
│   ├── README.md
│   ├── example-app/
│   │   ├── README.md              ← project overview
│   │   ├── roadmap.md             ← project roadmap
│   │   ├── handover-assessment.md ← if onboarded via /handover
│   │   └── notes/
│   ├── billing-api/
│   │   └── ...
│   └── marketing-site/
│       └── ...
│
└── docs/
    └── multi-project.md           ← full setup guide
```

## Why two parallel directories?

| Directory | Purpose | Tracked in ops repo? | Tracked in project repo? |
|-----------|---------|----------------------|--------------------------|
| `workspace/<name>/` | Real git clone of the project — where code edits, builds, and `git push` happen | **No** (`.gitignore` it) | Yes (it's the project itself) |
| `projects/<name>/` | ApexStack-managed docs **about** the project that span multiple commits or live above the repo level | **Yes** | No |

The split lets you keep:

- **Cross-cutting docs** (handover assessments, multi-quarter roadmaps, decision logs that aren't tied to a single PR) in the **ops repo**, version-controlled with the rest of your operating model
- **Code and code-adjacent docs** (READMEs, ADRs, AgDRs about specific commits) inside each **project's own repo**, where they belong

If you're not sure where a doc belongs, ask: "Would I want this doc to follow the code if the project was spun out tomorrow?" If yes → `workspace/<name>/docs/`. If no → `projects/<name>/`.

## Recommended `.gitignore` for an ops repo

```
# Don't commit live working copies — they have their own remotes
workspace/*/
!workspace/README.md
```

## Running skills against the workspace

Portfolio skills iterate the registry; project-specific ones use the current working directory.

```
/projects                  # all managed projects
/projects --status active

/status                    # all projects
/status --project example-app

/inbox                     # all PRs/issues/comments waiting on you
/tasks                     # actionable list with URLs
/handover marketing-site   # generates projects/marketing-site/handover-assessment.md
/roadmap show --project example-app
/stakeholder-update weekly --project example-app
```

To work on a specific project's code, `cd workspace/<name>` first — that puts your shell inside the real repo where branches, PRs, and CI live. Skills like `/decide`, `/code-review`, and `/security-review` operate on whatever working directory you're in.

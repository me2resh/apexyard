# `workspace/` — Live Project Clones

This directory holds **live working copies** of projects that ApexStack manages. It's part of the default layout. In single-project mode (the opt-in for one-repo teams) you can ignore it.

## The two modes

ApexStack supports two operating modes, set in `onboarding.yaml`:

```yaml
apexstack:
  mode: multi-project    # default
  # mode: single-project # opt-in
```

### Multi-project mode (the default)

When you manage **multiple repos as one organisation** (e.g. a CTO running an ops repo across 3–10 products), ApexStack aggregates across all of them. Skills like `/projects`, `/inbox`, `/status`, and `/tasks` iterate over a registry instead of looking at one repo. Most engineering orgs have more than one repo, so this is the right default — even a "single product" team usually has an app + infra + a marketing site.

How the default works:

1. `apexstack.mode` is read from `onboarding.yaml`; missing or `multi-project` → multi-project mode
2. `apexstack.projects.yaml` at the root of your **ops repo** holds the registry (see `apexstack.projects.yaml.example` for the schema)
3. Optionally clone each managed repo into `workspace/<name>/` (live working copies)
4. Add per-project docs under `projects/<name>/`

### Single-project mode (opt-in)

ApexStack is checked out into your project's repo (or kept globally at `~/.apexstack/`), and the rules and skills apply to that one repo. There is no `workspace/` directory you need to care about. Your code is just... your code, in its own repo. This is the right choice for solo developers and teams with exactly one product.

```
your-app/
├── .claude/                ← rules, skills, hooks (from ApexStack)
├── src/
├── tests/
├── package.json
└── ROADMAP.md              ← single-project roadmap lives at the root
```

To opt in: set `apexstack.mode: single-project` in `onboarding.yaml`.

## Directory layout under multi-project mode

```
my-ops-repo/
├── .claude/                       ← shared rules, skills, hooks
├── apexstack.projects.yaml        ← the registry (which projects ApexStack manages)
├── onboarding.yaml                ← apexstack.mode: multi-project
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
    └── multi-project.md           ← in-depth guide
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

Most skills auto-detect mode and iterate the registry:

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

To work on a specific project's code, `cd workspace/<name>` first — that puts your shell inside the real repo where branches, PRs, and CI live.

## Migrating from single → multi

See `docs/multi-project.md` for the full guide. The short version:

1. Set `apexstack.mode: multi-project`
2. Create `apexstack.projects.yaml`
3. Move your existing roadmap from `ROADMAP.md` to `projects/<current-project>/roadmap.md`
4. Move ideas from `IDEAS.md` to `projects/ideas-backlog.md`
5. (Optional) Clone other repos into `workspace/`

You can always go back: just remove the registry and flip `mode` back to `single-project`.

# ApexStack Setup

ApexStack governs a **portfolio of repos as one organisation**. You fork apexstack, clone the fork, treat it as your "ops repo", and register every project you want under management. This document is the full setup guide: the fork flow, the directory layout, the daily workflow, and the FAQ.

> There is no single-project fallback mode. Even if you have exactly one repo, you still fork apexstack and register that one repo. Future projects plug into the same registry.

---

## TL;DR

| | ApexStack |
|---|---|
| **What you install** | A fork of `me2resh/apexstack`, cloned locally. No `.apexstack/` symlinks, no nested installs. |
| **What governs the portfolio** | `apexstack.projects.yaml` at the root of your fork |
| **Where per-project docs live** | `projects/<name>/` inside your fork, committed |
| **Where live working copies live** | `workspace/<name>/` inside your fork, gitignored |
| **Where the registry, roadmap, ideas, updates live** | All inside your fork, alongside the apexstack primitives |
| **How upgrades flow** | `git pull upstream main` from `me2resh/apexstack` |
| **Best for** | CTOs, engineering leads, Chief-of-Staff roles managing 2+ repos (or 1 repo with intent to grow) |

---

## Why fork instead of clone?

Earlier versions of apexstack told you to clone the repo into a hidden `.apexstack/` directory inside a separate ops repo and symlink the `.claude/` folder. That pattern worked but it had three problems:

1. **Brand invisibility** — `.apexstack/` is a dotfile, hidden from `ls` and GitHub views. Nobody knew you were using apexstack.
2. **Two repos to maintain** — your ops repo plus the nested clone. Upgrades meant `git pull` in `.apexstack/`, which felt off-piste.
3. **Symlink fragility** — the `.claude/` symlink broke on dotfile sync tools and Windows setups.

Forking solves all three:

1. **The fork stays named** (keep it as `your-org/apexstack`, or rename to `your-org/ops` — your call)
2. **One repo to maintain** — the fork IS the ops repo
3. **Upgrades via the normal fork workflow** — `git pull upstream main`, resolve conflicts, done

---

## Setup — 6 steps, ~5 minutes

### 1. Fork on GitHub

Visit [`github.com/me2resh/apexstack`](https://github.com/me2resh/apexstack) and click **Fork** (top right). Star it while you're there.

The fork lands in your org. You can keep the name as `apexstack` or rename to something that fits your naming convention (`your-org/ops`, `your-org/apex`, `your-org/cos` for Chief-of-Staff — whatever suits).

### 2. Clone your fork locally

Using the GitHub CLI:

```bash
gh repo clone your-org/apexstack
cd apexstack
```

Or plain git:

```bash
git clone https://github.com/your-org/apexstack.git
cd apexstack
```

### 3. Add `upstream` for future updates

```bash
git remote add upstream https://github.com/me2resh/apexstack.git
```

Now `git fetch upstream` will pull the latest apexstack changes whenever you want to upgrade, and `git merge upstream/main` brings them into your fork.

### 4. Fill in `onboarding.yaml`

Edit the file at the repo root. Set company, team, tech stack, quality bar. Defaults are sensible — change what matters for your team.

```bash
$EDITOR onboarding.yaml
```

### 5. Create the registry

Copy the example and list every repo you want under management:

```bash
cp apexstack.projects.yaml.example apexstack.projects.yaml
$EDITOR apexstack.projects.yaml
```

The minimal entry is:

```yaml
version: 1
projects:
  - name: example-app
    repo: your-org/example-app
    docs: projects/example-app
    status: active
```

Add `workspace`, `roles`, `tier`, `tags`, and `ticket_prefix` later as you need them. Even if you have just one repo right now, register it — the skills are happier with one registered project than with a dangling "assume the current directory" fallback.

### 6. Seed per-project docs

For each project in the registry, create the docs folder:

```
projects/example-app/
├── README.md      ← project overview, owners, links
└── roadmap.md     ← project-specific roadmap (optional)
```

Or run `/handover example-app` and the skill will generate a real assessment and seed the README. Then optionally clone the live working copy:

```bash
git clone github.com/your-org/example-app workspace/example-app
```

`workspace/*/` is already gitignored in apexstack, so the nested clone won't be double-tracked.

### Verify

```
/projects
```

You should see one row per registered project. Then:

```
/inbox
/status
/tasks
```

Each aggregates across every registered project. You're live.

---

## Directory layout

```
your-org/apexstack/                ← your fork, cloned locally (the "ops repo")
├── CLAUDE.md                      ← entry point Claude Code reads first
├── onboarding.yaml                ← company + team + stack config
├── apexstack.projects.yaml        ← the portfolio registry
│
├── .claude/                       ← shared rules, skills, hooks, agents
│   ├── rules/
│   ├── skills/
│   ├── hooks/
│   ├── agents/
│   └── settings.json
│
├── roles/                         ← 19 role definitions, upstream from apexstack
│   ├── engineering/
│   ├── product/
│   ├── design/
│   ├── security/
│   └── data/
│
├── workflows/                     ← SDLC, code review, deployment
├── templates/                     ← PRD, tech design, ADR, AgDR
├── golden-paths/                  ← reusable CI pipelines
├── site/                          ← the apexstack landing page (feel free to delete or replace)
│
├── workspace/                     ← LIVE WORKING COPIES (gitignored)
│   ├── README.md
│   ├── example-app/               ← `git clone`d, has its own .git/
│   ├── billing-api/
│   └── marketing-site/
│
├── projects/                      ← APEXSTACK DOCS PER PROJECT (committed)
│   ├── README.md
│   ├── ideas-backlog.md           ← shared ideas backlog
│   ├── example-app/
│   │   ├── README.md
│   │   ├── roadmap.md
│   │   ├── handover-assessment.md
│   │   └── updates/
│   ├── billing-api/
│   └── marketing-site/
│
└── docs/
    └── multi-project.md           ← this file
```

The split between `workspace/` and `projects/` is deliberate:

- **`workspace/<name>/`** is where you do code work. It's a real git clone of the project. Branches, PRs, and CI happen there. **It's gitignored in your fork** — each project has its own remote.
- **`projects/<name>/`** is where ApexStack docs about the project live. It's committed to your fork alongside the registry. Roadmaps, handover assessments, stakeholder updates all live here.

The test for *"where does this doc go?"* is **"would I want this to follow the code if the project was spun out tomorrow?"** If yes → put it in the project's own repo (i.e. inside `workspace/<name>/docs/`). If no → put it in `projects/<name>/` in your fork.

---

## How skills behave

Every portfolio skill reads `apexstack.projects.yaml` and iterates the registry.

| Skill | Behaviour |
|-------|-----------|
| `/projects` | Reads the registry, shows one row per project with status, branch, open PRs, open issues |
| `/status` | Same as `/projects` but with git + CI snapshots per project, separated by headers |
| `/inbox` | Aggregates PRs, issues, and comments needing your attention across every registered project |
| `/tasks` | Aggregated, scored, and sorted task list across the portfolio |
| `/idea` | Appends to `projects/ideas-backlog.md` at the fork root (one shared backlog for all projects) |
| `/roadmap` | Reads `projects/<name>/roadmap.md`; asks which project if ambiguous |
| `/stakeholder-update` | Portfolio rollup with a section per project |
| `/handover` | Writes to `projects/<name>/handover-assessment.md` and appends the project to the registry |
| `/c4` | Reads a project's codebase and writes filled-in C4 L1 + L2 Mermaid diagrams (location depends on invocation context — see `.claude/skills/c4/SKILL.md`) |

Skills that aren't portfolio-aware (`/decide`, `/write-spec`, `/code-review`, `/security-review`, `/audit-deps`) operate on the current working directory — `cd workspace/<name>/` first if you want them to run against a specific project's code.

---

## Architecture diagrams

Every managed project should have at least a **C4 Level 1 (System Context)** diagram, and ideally a **Level 2 (Container)** one. Diagrams are written as Mermaid inside Markdown files — GitHub renders them inline, zero build step.

Templates:

- `templates/architecture/c4-context.md` — L1, system + external actors
- `templates/architecture/c4-container.md` — L2, deployable units inside the system boundary

Where to put the diagrams (same split as every other kind of doc — "would this follow the code if the project spun out?"):

| Scope | Location |
|-------|----------|
| Framework-wide (ApexStack itself) | `docs/architecture/` in the ops fork |
| ApexStack's view of a managed project | `projects/<name>/architecture/` in the ops fork |
| Internal to a project's own repo | `docs/architecture/` in that project's repo (via `workspace/<name>/docs/architecture/`) |

ApexStack dogfoods its own convention — see `docs/architecture/apexstack-context.md` and `apexstack-container.md` for a worked example.

Decision rationale (tool choice — Mermaid C4 over Structurizr DSL / PlantUML / D2): [`docs/agdr/AgDR-0003-mermaid-c4-for-diagrams.md`](agdr/AgDR-0003-mermaid-c4-for-diagrams.md).

---

## Daily workflow

A typical morning as a CTO / Chief of Staff using apexstack:

1. **`cd ~/apexstack`** — into your fork
2. **`/inbox`** — see everything waiting on you across every managed project
3. **`/status`** — snapshot of git + CI health for each project
4. Pick a ticket, **`cd workspace/<project>/`**, pick up the ticket as the appropriate role (see [`.claude/rules/role-triggers.md`](../.claude/rules/role-triggers.md))
5. Work the ticket — the role file drives behaviour, the lifecycle demo in the hero of the landing site walks through the full flow
6. Back at the fork root, **`/stakeholder-update weekly`** on Fridays to generate the summary

---

## Upgrades — pulling from upstream

### How you know it's time

On every Claude Code session start, the `check-upstream-drift.sh` hook runs `git fetch upstream` (cached to once per 10 minutes) and prints a one-line banner if your fork is behind:

```
ApexStack: 12 commits behind upstream/main. Run /update to sync.
```

Silent if up-to-date, silent on network failure, silent if no `upstream` remote is configured. No extra startup cost when there's nothing to say.

### Syncing

Every few weeks, pull the latest apexstack improvements into your fork. The easy path is the `/update` skill:

```
/update              # preview + merge-based sync on a sync branch (default)
/update --rebase     # rebase-based sync (cleaner linear history)
/update --dry-run    # preview only, no state change
```

`/update` does the work of the manual flow below: fetches `upstream`, previews the commit delta, creates a sync branch (because `block-main-push.sh` forbids direct pushes to `main`), merges or rebases, walks through any conflicts with per-file options, and leaves the branch ready to push as a PR. See `.claude/skills/update/SKILL.md` for the full process.

If you prefer the raw commands:

```bash
cd ~/apexstack

# Get the latest upstream changes
git fetch upstream

# See what's new
git log --oneline HEAD..upstream/main

# On a sync branch (direct-push-to-main is blocked by block-main-push.sh)
git checkout -b chore/sync-upstream
git merge upstream/main

# Resolve any conflicts (usually in files you haven't customised — role files, workflow files, CLAUDE.md imports)
# Then push and open a PR
git push -u origin chore/sync-upstream
gh pr create --title "chore: sync ops fork with upstream apexstack"
```

Files you're most likely to customise:

- `onboarding.yaml` — always yours, never upstream
- `apexstack.projects.yaml` — always yours
- `projects/<name>/` — always yours
- `site/index.html` — delete or replace with your own landing page
- Role files in `roles/` — usually upstream, but feel free to edit for your team's voice

Files that stay close to upstream (merge cleanly most of the time):

- `.claude/hooks/` — shell scripts
- `.claude/rules/` — modular rule files
- `.claude/agents/` — sub-agent definitions
- `workflows/` — SDLC, code review, deployment
- `templates/` — PRD, tech design, ADR, AgDR
- `golden-paths/` — reusable CI pipelines

---

## Trade-offs

### Pros of the fork-as-ops-repo model

- **One repo to rule them all** — the fork IS the ops repo. No nested installs, no symlinks.
- **Brand visible** — if you keep the fork named `apexstack`, anyone looking at your org sees you're running the stack.
- **Upgrades are standard git** — `git pull upstream main`. No proprietary upgrade tool.
- **One inbox** — `/inbox` shows everything across the portfolio in ~1 second
- **Cross-project docs have a home** — stakeholder updates, handover assessments, multi-quarter roadmaps live in `projects/`
- **Consistent governance** — same rules, hooks, skills apply to every project automatically

### Cons

- **Registry drift** — if a project changes name or moves repos, you update the registry by hand
- **Two layers of git** — your fork has history, and each `workspace/<name>/` has its own — easy to confuse which one you're committing into
- **Not magical** — no auto-discovery of repos in your GitHub org. You register each one explicitly. (Deliberate — implicit discovery would be unsafe.)
- **Gitignore discipline required** — `workspace/*/` is gitignored upstream, but if you accidentally add a working copy with `git add -f` you'll regret it fast
- **Conflict resolution on upgrade** — merging upstream occasionally creates conflicts in files you've customised. Usually small, but not zero.

---

## FAQ

**Can I have two ops repos?** Yes. Some teams split by domain (e.g. one ops repo for product, one for platform). Each ops repo is an independent fork of apexstack with its own registry.

**Can a project be in two registries?** Technically yes, but don't. It defeats the "single source of truth" benefit and creates conflicts in `projects/<name>/`. Pick one ops repo per project.

**Do I need to clone every project locally?** No. The `workspace` field in the registry is optional. Skills will use GitHub-only data and mark git fields as `(not cloned)` for projects without a local clone.

**Does `/decide` write AgDRs to the fork or the project repo?** The project repo. AgDRs are tied to commits, so they live with the code. `/decide` always writes to `{cwd}/docs/agdr/`, which means you need to `cd workspace/<name>/` first.

**Does the registry support globs?** No. It's an explicit list. If you want all repos in an org, use `gh repo list` to generate the file once and commit the result — but you should still curate it.

**Can I use this with Linear / Jira / etc.?** Yes. Set `ticket_prefix` per project in the registry. Skills that read tickets will use the right prefix per project.

**What if I only have one repo?** Fork apexstack anyway and register that one repo. The skills work the same way. When you add a second project, just append to the registry — no migration, no re-setup.

**Can I delete the landing page (`site/`)?** Yes — it's the apexstack marketing site. Feel free to delete, replace, or leave it in place. It doesn't affect the rest of the stack.

**Can I rename my fork?** Yes. GitHub handles rename redirects cleanly. Your local clone will need `git remote set-url origin` after the rename.

---

## Related docs

- `apexstack.projects.yaml.example` — the registry schema
- `workspace/README.md` — the live working copies convention
- `projects/README.md` — the per-project docs convention
- `onboarding.yaml` — company + team + stack config
- `.claude/rules/role-triggers.md` — when to activate which role
- `.claude/skills/projects/SKILL.md` — the `/projects` skill spec
- `.claude/skills/handover/SKILL.md` — the `/handover` skill spec

# ApexYard Setup

ApexYard governs a **portfolio of repos as one organisation**. You fork apexyard, clone the fork, treat it as your "ops repo", and register every project you want under management. This document is the full setup guide: the fork flow, the directory layout, the daily workflow, and the FAQ.

> There is no single-project fallback mode. Even if you have exactly one repo, you still fork apexyard and register that one repo. Future projects plug into the same registry.

---

## Two setup modes — pick the one that matches your privacy needs

ApexYard ships two supported patterns. **Read this section before you fork** — picking the wrong one and pushing private project names to a public fork is hard to recover from cleanly (the GitHub PR / Issue edit history survives a force-push).

| | Single-fork mode (default) | Split-portfolio mode (v2) |
| --- | --- | --- |
| **Repos** | One: your fork of `me2resh/apexyard` | Two: public fork **+** a separate private repo for the portfolio |
| **Where the registry lives** | `apexyard.projects.yaml` in the fork | `apexyard.projects.yaml` in the private repo, resolved via config block |
| **Where `projects/<name>/` lives** | Inside the fork | Inside the private repo, resolved via config block |
| **Where `onboarding.yaml` lives** | Inside the fork | Inside the private repo (v2, framework ≥ #242) |
| **Where `workspace/<name>/` lives** | Inside the fork (gitignored) | Inside the private repo (v2, framework ≥ #242) |
| **Ops-fork anchor on disk** | `onboarding.yaml + apexyard.projects.yaml` (legacy) — or `.apexyard-fork` marker file (v2) | `.apexyard-fork` marker file (v2) — neither legacy file is in the public fork |
| **Public exposure** | Every registered project name + handover finding is on a public GitHub repo | Public fork holds only framework files + your customisations; private repo holds your portfolio data, company config, AND your managed-project clones |
| **Daily workflow** | Same | Same — skills resolve through the config block transparently |
| **Pick this if…** | All your projects are already public, OR you're on GitHub Pro / Team / Enterprise (which support private forks of public repos) | You're on GitHub Free with any project you don't want named publicly |

**The trip-wire**: GitHub Free disallows changing a fork's visibility — you cannot make a fork of a public repo private after the fact. Combined with the framework's default of committing the registry to the fork, free-tier adopters with any private project risk accidentally publishing their portfolio names with a stray push (the framework itself never pushes without operator approval, but once the registry is committed locally the next push exposes it). The split-portfolio mode below is the supported way around this.

---

## TL;DR — single-fork mode (default)

| | ApexYard (single-fork) |
| --- | --- |
| **What you install** | A fork of `me2resh/apexyard`, cloned locally. No `.apexyard/` symlinks, no nested installs. |
| **What governs the portfolio** | `apexyard.projects.yaml` at the root of your fork |
| **Where per-project docs live** | `projects/<name>/` inside your fork, committed |
| **Where live working copies live** | `workspace/<name>/` inside your fork, gitignored |
| **Where the registry, roadmap, ideas, updates live** | All inside your fork, alongside the apexyard primitives |
| **How upgrades flow** | `git pull upstream main` from `me2resh/apexyard` |
| **Best for** | CTOs, engineering leads, Chief-of-Staff roles managing 2+ repos (or 1 repo with intent to grow) — **all projects public, OR you have GitHub Pro / Team / Enterprise** |

If you need privacy, jump to the [split-portfolio setup](#split-portfolio-mode--public-framework--private-portfolio) further down.

---

## Why fork instead of clone?

Earlier versions of apexyard told you to clone the repo into a hidden `.apexyard/` directory inside a separate ops repo and symlink the `.apexyard/` folder. That pattern worked but it had three problems:

1. **Brand invisibility** — `.apexyard/` is a dotfile, hidden from `ls` and GitHub views. Nobody knew you were using apexyard.
2. **Two repos to maintain** — your ops repo plus the nested clone. Upgrades meant `git pull` in `.apexyard/`, which felt off-piste.
3. **Symlink fragility** — the `.apexyard/` symlink broke on dotfile sync tools and Windows setups.

Forking solves all three:

1. **The fork stays named** (keep it as `your-org/apexyard`, or rename to `your-org/ops` — your call)
2. **One repo to maintain** — the fork IS the ops repo
3. **Upgrades via the normal fork workflow** — `git pull upstream main`, resolve conflicts, done

---

## Setup — 6 steps, ~5 minutes

### 1. Fork on GitHub

Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard) and click **Fork** (top right). Star it while you're there.

The fork lands in your org. You can keep the name as `apexyard` or rename to something that fits your naming convention (`your-org/ops`, `your-org/apex`, `your-org/cos` for Chief-of-Staff — whatever suits).

### 2. Clone your fork locally

Using the GitHub CLI:

```bash
gh repo clone your-org/apexyard
cd apexyard
```

Or plain git:

```bash
git clone https://github.com/your-org/apexyard.git
cd apexyard
```

### 3. Add `upstream` for future updates

```bash
git remote add upstream https://github.com/me2resh/apexyard.git
```

Now `git fetch upstream` will pull the latest apexyard changes whenever you want to upgrade, and `git merge upstream/main` brings them into your fork.

### 4. Fill in `onboarding.yaml`

The repo ships a tracked placeholder template, `onboarding.example.yaml`. Your real config lives in `onboarding.yaml`, which is **gitignored** (#517) — it stays local and is never published to your public fork or an upstream PR. Copy the template, then edit it (or just run `/setup`, which does the copy + fill for you):

```bash
cp onboarding.example.yaml onboarding.yaml
$EDITOR onboarding.yaml      # set company, team, tech stack, quality bar
```

Don't commit `onboarding.yaml` — a commit-time guard (`block-onboarding-in-git.sh`) blocks a filled-in copy if you try. If a teammate needs the config *shape*, edit and commit `onboarding.example.yaml` (placeholders only) instead.

> **Migrating an existing fork (pre-#517, where `onboarding.yaml` was tracked):** untrack it once — your local copy is preserved — and let the new gitignore + guard take over:
>
> ```bash
> git rm --cached onboarding.yaml
> git commit -m "chore: untrack onboarding.yaml (now gitignored, #517)"
> ```
>
> The real values still exist in prior git history; scrub history separately if the fork is public and the old values are sensitive (see the security-hardening full-history sweep).

### 5. Create the registry

Copy the example and list every repo you want under management:

```bash
cp apexyard.projects.yaml.example apexyard.projects.yaml
$EDITOR apexyard.projects.yaml
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

Or run `/handover example-app` and the skill will generate a real assessment and seed the README. At the end of its flow, `/handover` also **offers (default-no) to clone the project into `workspace/<name>/`** — accept if you intend to follow up with `/code-review`, `/threat-model`, or `/security-review` and want the LSP-aware deep-dive path; decline if you'd rather configure `ENABLE_LSP_TOOL=1` + the per-language plugin first, or skip the deep dive entirely. The prompt surfaces the disk cost, the gitignored status (`workspace/*/`), and the LSP plugin caveats explicitly so the cost is owned, not assumed.

If you'd rather clone manually:

```bash
git clone github.com/your-org/example-app workspace/example-app
```

`workspace/*/` is already gitignored in apexyard, so the nested clone won't be double-tracked.

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

## Split-portfolio mode — public framework + private portfolio

Use this mode if you're on GitHub Free with any project you don't want named publicly. The fork stays public + upstream-aligned; a separate private repo holds the registry + per-project docs.

### Layout

```
~/ops/
├── apexyard/                ← public fork of me2resh/apexyard (framework code + tooling)
└── apexyard-portfolio/      ← private repo (registry + per-project docs — never goes public)
```

The default sibling-dir name is **`<fork>-portfolio`**, so the relationship between the two repos is self-documenting on disk and on GitHub. If you kept the fork name as `apexyard`, the sibling defaults to `apexyard-portfolio`. If you renamed the fork (e.g. `cos` for Chief-of-Staff), the sibling defaults to `cos-portfolio`. Pick something else if you'd prefer — the framework only cares about the local path you point the config block at.

Both repos live in your account; on disk they sit side-by-side. Inside the apexyard fork, the framework's portfolio-aware skills resolve `apexyard.projects.yaml`, `projects/`, **`onboarding.yaml`** (v2), and **`workspace/`** (v2) through one of two mechanisms:

- **Config block (recommended, framework ≥ #145; v2 keys added in #242).** A `portfolio:` block in `.apexyard/project-config.json` points the skills at `../apexyard-portfolio/apexyard.projects.yaml`, `../apexyard-portfolio/projects`, `../apexyard-portfolio/onboarding.yaml`, and `../apexyard-portfolio/workspace`. The `_lib-portfolio-paths.sh` helper resolves all five (`registry`, `projects_dir`, `ideas_backlog`, `onboarding`, `workspace_dir`). A `SessionStart` banner surfaces broken config (missing files, bad paths) at session start so you don't discover a misconfiguration mid-skill.
- **Symlink (legacy, framework < #145).** `apexyard.projects.yaml` and `projects/` are symlinks into the portfolio repo (and gitignored from the fork itself). Existing skills resolve through the symlink transparently. Continues to work; if you're upgrading framework versions, prefer the config block. The v2 additions (`onboarding`, `workspace_dir`) are config-block only — there is no legacy symlink path for them.

**The v2 additions: why both `onboarding.yaml` and `workspace/` move to the private repo.** Earlier split-portfolio releases (v1, framework < #242) kept `onboarding.yaml` (your company name, mission, team list, tech stack) AND `workspace/<name>/` (the local clones of your managed projects) in the public fork. Both leak. The v1 layout meant a CTO running ApexYard on a private SaaS effectively published their team roster + tech-stack + every project name on a public GitHub repo via routine session activity. v2 closes that gap: every adopter-specific artefact lives in the private sibling repo; the public fork holds only framework files plus the operator's customisations to skills/hooks/rules.

**The ops-fork anchor under v2.** Pre-v2 every hook + skill that walked up to find the ops fork looked for BOTH `onboarding.yaml` AND `apexyard.projects.yaml` at the candidate dir. Under v2, neither file is in the public fork — the walk-up condition fails. v2 introduces a presence-only marker file `.apexyard-fork` at the public-fork root; `_lib-ops-root.sh` and every walk-up consumer recognises both anchors (v2 marker first, legacy v1 pair as fallback for un-migrated adopters during the transition window).

The `/split-portfolio` skill (introduced #146) automates the single-fork → split-portfolio migration. The `/update` skill (extended in #242) automates the v1 → v2 split-portfolio migration for adopters who're already split but on the older layout — see § "Migrating from split-portfolio v1 to v2" below.

### Setup — 7 steps, ~6 minutes

#### 1. Fork apexyard on GitHub

Same as single-fork mode. Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard) → click **Fork**. Lands in your account as `your-org/apexyard` (public). Keep the name as `apexyard`.

#### 2. Create an empty private repo for your portfolio

```bash
gh repo create your-org/apexyard-portfolio --private \
  --description "ApexYard private portfolio: registry + per-project handover docs"
```

The default convention is **`<fork>-portfolio`** — keeps the relationship to the public fork clear on GitHub and on disk. If your fork is named `your-org/apexyard`, the portfolio is `your-org/apexyard-portfolio`. If you renamed the fork (`your-org/cos`, `your-org/apex`), use `<fork>-portfolio` accordingly. Pick a different name if you prefer — the framework only cares about the local path you point the config block at.

#### 3. Clone both side-by-side

```bash
mkdir ~/ops && cd ~/ops
gh repo clone your-org/apexyard
gh repo clone your-org/apexyard-portfolio
```

Resulting layout:

```
~/ops/
├── apexyard/                ← public fork
└── apexyard-portfolio/      ← private (currently empty)
```

#### 4. Add `upstream` for future updates

```bash
cd ~/ops/apexyard
git remote add upstream https://github.com/me2resh/apexyard.git
```

#### 5. Initialise the private portfolio (v2 layout)

```bash
cd ~/ops/apexyard-portfolio

cat > apexyard.projects.yaml <<EOF
version: 1
projects: []
defaults:
  status: active
  ticket_prefix: GH
EOF

# v2: onboarding.yaml lives here too. Seed from the framework template
# OR run /setup later inside the public fork — /setup writes to the
# resolved onboarding path.
cp ~/ops/apexyard/onboarding.yaml.example onboarding.yaml 2>/dev/null \
  || cp ~/ops/apexyard/onboarding.yaml onboarding.yaml 2>/dev/null \
  || cat > onboarding.yaml <<'YAML'
company:
  name: "Your Company Name"
  mission: ""
YAML

# v2: workspace/ lives here too. Empty dir to start; /handover and
# manual `git clone workspace/<name>` will populate it.
mkdir -p projects workspace

# Ignore the inner managed-project clones inside workspace/ so they
# don't get double-tracked in the private repo either.
cat > .gitignore <<'IGNORE'
workspace/*/
IGNORE

# Keep the dirs alive across the initial commit.
touch projects/.gitkeep workspace/.gitkeep

git add apexyard.projects.yaml onboarding.yaml projects workspace .gitignore
git commit -m "chore: initialise private portfolio (split-portfolio v2)"
git push
```

#### 6. Gitignore the portfolio paths in the fork + configure path resolution

The recommended path is the **config block** (framework version ≥ #145). The symlink approach below is the legacy fallback for older framework versions — both work.

##### Recommended: config-block mode (v2)

```bash
cd ~/ops/apexyard

# Tell the fork to ignore everything that lives in the private repo:
# registry, per-project docs, onboarding config, and the workspace dir.
cat >> .gitignore <<'EOF'

# Portfolio data lives in a separate private repo (split-portfolio v2).
# See docs/multi-project.md.
apexyard.projects.yaml
projects
onboarding.yaml
workspace
EOF

# If any of these are currently tracked from the upstream framework,
# untrack them so the config-block resolution can take their place:
git rm -r --cached projects onboarding.yaml workspace 2>/dev/null || true

# Write the v2 portfolio: config block pointing at the sibling repo.
# Paths resolve relative to the ops-fork root (this directory).
# If you used a different sibling-dir name than apexyard-portfolio,
# substitute it in all five paths below.
cat > .apexyard/project-config.json <<'JSON'
{
  "portfolio": {
    "registry": "../apexyard-portfolio/apexyard.projects.yaml",
    "projects_dir": "../apexyard-portfolio/projects",
    "ideas_backlog": "../apexyard-portfolio/projects/ideas-backlog.md",
    "onboarding": "../apexyard-portfolio/onboarding.yaml",
    "workspace_dir": "../apexyard-portfolio/workspace"
  }
}
JSON

# Write the v2 ops-fork anchor. Presence-only marker; content is ignored
# but a short identifying line helps human grep. Every framework hook
# that walks up to find the ops fork looks for this marker first
# (legacy onboarding.yaml + apexyard.projects.yaml pair stays as a
# fallback for un-migrated forks).
echo "# This file marks the directory as an ApexYard ops fork (split-portfolio v2)." > .apexyard-fork

git add .gitignore .apexyard/project-config.json .apexyard-fork
git commit -m "chore: configure split-portfolio v2 (config-block path resolution + marker)"
git push
```

The `SessionStart` hook chain calls `portfolio_validate` from `_lib-portfolio-paths.sh` on every session start. If the resolved registry / projects_dir / ideas_backlog / onboarding / workspace_dir paths are broken (typo, missing file, etc.), you'll see a one-line banner naming the failure. Silent on success.

##### Legacy: symlink-based mode (framework < #145)

If you're on an older framework version that doesn't have the `portfolio:` config block, fall back to symlinks. The skills resolve through them transparently — same end result, less first-class:

```bash
cd ~/ops/apexyard

# Tell the fork to ignore the registry + projects/ — they live in the portfolio.
cat >> .gitignore <<'EOF'

# Portfolio data lives in a separate private repo (split-portfolio mode).
# See docs/multi-project.md.
apexyard.projects.yaml
projects
EOF

# If projects/README.md is currently tracked from the upstream framework,
# untrack it so the symlink can take its place:
git rm -r --cached projects 2>/dev/null || true

# Symlink the registry and projects/ into the portfolio repo:
ln -s ../apexyard-portfolio/apexyard.projects.yaml apexyard.projects.yaml
ln -s ../apexyard-portfolio/projects projects

git add .gitignore
git commit -m "chore: configure split-portfolio mode (registry + projects/ in private sibling repo)"
git push
```

#### 7. Verify

From the fork dir:

```bash
cd ~/ops/apexyard
/projects   # should resolve through the symlink and report 0 entries (or whatever's in your portfolio)
```

Adopt your first project with `/handover` — it writes to `../apexyard-portfolio/projects/<name>/` and appends to `../apexyard-portfolio/apexyard.projects.yaml`, both committed only to the private portfolio repo. The public fork stays slim.

### Custom templates

Every framework template (PRD, AgDR, migration AgDR, C4 context/container, vision, spike, etc.) can be overridden by an adopter-authored version. The mechanism is **path-mirroring** — drop your version at `<private_repo>/custom-templates/<path>` and it wins over the framework default at `templates/<path>`. No frontmatter, no config table, no registry.

```
~/ops/apexyard-portfolio/
├── apexyard.projects.yaml
├── projects/
├── custom-templates/                    ← drop overrides here
│   ├── prd.md                           ← overrides templates/prd.md
│   ├── agdr.md                          ← overrides templates/agdr.md
│   ├── agdr-migration.md                ← overrides templates/agdr-migration.md
│   ├── tickets/
│   │   ├── feature.md                   ← overrides templates/tickets/feature.md
│   │   ├── bug.md                       ← overrides templates/tickets/bug.md
│   │   ├── task.md                      ← overrides templates/tickets/task.md
│   │   ├── migration.md                 ← overrides templates/tickets/migration.md
│   │   ├── idea.md                      ← overrides templates/tickets/idea.md
│   │   ├── spike.md                     ← overrides templates/tickets/spike.md
│   │   └── investigation.md             ← overrides templates/tickets/investigation.md
│   └── architecture/
│       ├── c4-context.md                ← overrides templates/architecture/c4-context.md
│       └── c4-container.md              ← overrides templates/architecture/c4-container.md
└── README.md
```

Why path-mirroring instead of frontmatter or a config table? Discovery is the convention itself — if you want to override `templates/<path>`, you put your version at `custom-templates/<path>`. Same shape as how `handbooks/<dim>/...` discovery works (#232). And resolution is **override, not additive**: an authored `custom-templates/prd.md` wins in full; the framework's `templates/prd.md` is ignored for that invocation. Templates are *forms*, not *content*, so partial-merge across two markdown files would be unreliable. Copy the framework default in full, then edit it.

Single-fork adopters drop overrides at `<fork>/custom-templates/<path>` (sibling to `templates/`). Same resolution rule — adopters with no `custom-templates/` dir get the framework default automatically, zero behaviour change.

The `_lib-portfolio-paths.sh` helper exposes `portfolio_resolve_template <relative_path>` (e.g. `portfolio_resolve_template architecture/c4-context.md`); every template-consuming skill (`/decide`, `/write-spec`, `/c4`, `/migration`, `/spike`, `/handover`) routes through it. Full reference: [`templates/README.md`](../templates/README.md). Design rationale: [`AgDR-0023`](agdr/AgDR-0023-custom-templates-override-semantics.md).

To seed the directory in your private repo, copy the example README that ships with the framework:

```bash
cd ~/ops/apexyard-portfolio
mkdir -p custom-templates
cp ../apexyard/templates/custom-templates.README.example.md custom-templates/README.md
git add custom-templates
git commit -m "chore: scaffold custom-templates/ for adopter overrides"
```

The README is a starting point — the resolver doesn't read it; it's there for future-you and any human collaborator.

### Daily workflow under split mode

```bash
cd ~/ops/apexyard      # framework changes go here, push to public fork
cd ~/ops/apexyard-portfolio     # registry + project docs changes go here, push to private repo
```

Most ApexYard skills (`/projects`, `/inbox`, `/status`, `/tasks`, `/stakeholder-update`, `/handover`) work from the apexyard dir — they resolve paths through the symlinks. Skills that touch framework files only (`/update`, `/release`) operate on the apexyard dir alone.

#### Where session-state files live

Framework session state — active-ticket markers, code-review approvals, CEO approvals, the bootstrap-skill marker — always lives at `<ops_fork_root>/.apexyard/session/`. **Not** inside any `workspace/<project>/` clone.

This matters when you `cd workspace/<project>/` to do project-specific work: even though `git rev-parse --show-toplevel` from inside the clone returns the project clone (not the ops fork), the framework's hooks, agents, and skills (Rex, `/start-ticket`, `/approve-merge`, the merge-gate hooks) all walk up to find the ops fork and write/read session state from there. The `_lib-ops-root.sh` helper (added in me2resh/apexyard#229 + #230, extended for v2 in #242) centralises the walk and recognises BOTH the v2 `.apexyard-fork` marker AND the legacy v1 pair (`onboarding.yaml + apexyard.projects.yaml`) — so all components agree on the canonical path under either layout.

The same dual-anchor rule applies to the `.claude/settings.json` hook wrappers themselves (every `SessionStart` / `PreToolUse` / `PostToolUse` entry walks up to locate `.apexyard/hooks/<name>.sh` before exec'ing it). Adopters writing new entries — or framework PRs adding new SessionStart hooks — should use the canonical v2-aware wrapper documented in [`AgDR-0041`](agdr/AgDR-0041-sessionstart-v2-anchor-sweep.md). The old `onboarding.yaml`-only walk-up shape silently fails on v2 forks.

> **Note on wrapper-level v1 detection laxness.** The wrappers accept `onboarding.yaml` alone as the v1 anchor, while `_lib-ops-root.sh` (the in-hook resolver) requires BOTH `onboarding.yaml` AND `apexyard.projects.yaml`. This is deliberate: the wrapper only needs to locate `.apexyard/hooks/<name>.sh` and `exec` it, so a single marker suffices. The hook itself does the stricter canonical ops-root check internally via the lib. See [AgDR-0041](agdr/AgDR-0041-sessionstart-v2-anchor-sweep.md) § "Decision" point 2 for the full rationale.

You'll never need to manage session-state files by hand. If you ever see a "BLOCKED: PR has no recorded code-reviewer approval" error after the agent visibly approved, check that at least one of the ops-fork anchors is present at the fork root: `.apexyard-fork` (v2) OR both `onboarding.yaml` AND `apexyard.projects.yaml` (v1).

### Upstream sync under split mode

`/update` works the same. The upstream framework occasionally ships changes to `projects/README.md` (the framework's per-project docs convention). After the symlink, your fork's `projects/README.md` is replaced by the portfolio's own README. If a future upstream sync wants to update `projects/README.md`, you'll see a conflict; resolve by either accepting the upstream version (re-tracks the file, replacing the symlink behaviour for that one path) or keeping your symlink. Most upstream releases don't touch this file.

### What this mode trades off

- **Two repos to maintain** instead of one. Both live in the same GitHub account; trivial overhead.
- **Two clones on each machine.** Cross-machine setup is `gh repo clone your-org/apexyard && gh repo clone your-org/apexyard-portfolio` instead of one clone.
- **No automatic GitHub-UI fork-of-the-portfolio.** The portfolio repo is independent. Backups happen via your normal git push to your private GitHub repo.
- **One conflict path on `/update`** (the `projects/README.md` case above). Resolved manually if it ever fires.

In exchange, **zero of your private project names ever land on a public GitHub repo**, ever.

### Private custom skills + handbooks

Split-portfolio mode also houses two layers of company-specific customisation that wouldn't be safe to publish on the public fork (introduced in framework #243):

| Layer | Where in the private repo | What lives here |
| --- | --- | --- |
| **Custom skills** | `<private_repo>/custom-skills/<name>/SKILL.md` | Company-specific proprietary slash commands — `/file-internal-bug` against your internal tracker, `/check-policy` against a private compliance corpus, `/escalate-to-pagerduty`, etc. |
| **Custom handbooks** | `<private_repo>/custom-handbooks/{architecture,general,language/<lang>}/*.md` | Company-confidential coding standards that name internal systems, refer to proprietary policy, or otherwise don't belong on a public repo. Same path-convention as the public `handbooks/` tree. |

#### How discovery works

- **Custom skills** — Claude Code discovers skills by walking `.apexyard/skills/<name>/SKILL.md` in the active fork. We don't control that glob path. The `link-custom-skills.sh` SessionStart hook fixes that gap: on every session start it iterates `<private_repo>/custom-skills/<name>/`, and for each subdirectory containing a `SKILL.md` it creates a gitignored symlink at `.apexyard/skills/<name>/` pointing into the private dir. Claude Code then sees the skill transparently. **Custom skills with the same name as a framework skill win** — the hook moves the framework version to `.apexyard/skills/<name>.framework.bak/` (gitignored) and prints a one-line warning at SessionStart so the override is visible. **Windows is not supported in v1**; the hook prints a one-line manual-install pointer and skips. Same shape as the LSP install on Windows.
- **Custom handbooks** — Rex's agent prompt (`.apexyard/agents/code-reviewer.md` § 8) gains a second discovery path. The `portfolio_custom_handbooks_dir` resolver in `_lib-portfolio-paths.sh` returns the private dir; Rex globs both the public `handbooks/` tree AND the private one using the same architecture/general/language convention. No symlinks involved — handbooks aren't discovered by Claude Code, only by Rex's prompt, so a second glob is enough. Per-handbook precedence on overlapping topics: **Rex applies BOTH layers** and cites both when relevant; conflict resolution is the operator's responsibility (write it as prose in the custom handbook).

#### Setup

`/setup --split-portfolio` (or step 5 of the manual setup above) creates the two empty dirs in the private repo with a one-paragraph README explaining the convention. The two new keys go in your config block alongside the existing v2 keys:

```json
{
  "portfolio": {
    "registry":             "../apexyard-portfolio/apexyard.projects.yaml",
    "projects_dir":         "../apexyard-portfolio/projects",
    "ideas_backlog":        "../apexyard-portfolio/projects/ideas-backlog.md",
    "onboarding":           "../apexyard-portfolio/onboarding.yaml",
    "workspace_dir":        "../apexyard-portfolio/workspace",
    "custom_skills_dir":    "../apexyard-portfolio/custom-skills",
    "custom_handbooks_dir": "../apexyard-portfolio/custom-handbooks"
  }
}
```

The two `custom_*_dir` keys are optional — defaults resolve to `./custom-skills` and `./custom-handbooks` against the ops-fork root. For split-portfolio adopters, set them explicitly to the sibling repo so the dirs come out of the private layer.

#### Authoring a custom skill

Manual `cp + edit` is fine for v1 — there's no `/custom-skill` authoring helper:

```bash
cd ~/ops/apexyard-portfolio

# Copy a framework skill as a starting shape (or write from scratch)
cp -R ~/ops/apexyard/.apexyard/skills/feature custom-skills/file-internal-bug
$EDITOR custom-skills/file-internal-bug/SKILL.md   # adjust frontmatter (name, description, argument-hint)

git add custom-skills/file-internal-bug
git commit -m "feat: add /file-internal-bug for the internal tracker"
git push
```

Next session start in the public fork, the `link-custom-skills.sh` SessionStart hook surfaces the new skill as `.apexyard/skills/file-internal-bug/` and Claude Code starts discovering it.

#### Authoring a custom handbook

Same as the public-handbook convention — copy a sample, edit, commit:

```bash
cd ~/ops/apexyard-portfolio
mkdir -p custom-handbooks/architecture
cp ~/ops/apexyard/handbooks/architecture/clean-architecture-layers.md custom-handbooks/architecture/internal-pii-handling.md
$EDITOR custom-handbooks/architecture/internal-pii-handling.md   # write the rule
git add custom-handbooks/architecture/internal-pii-handling.md
git commit -m "docs: handbook on internal PII handling"
```

Next code review, Rex globs both `handbooks/architecture/*.md` AND `<private>/custom-handbooks/architecture/*.md` and applies findings from both. Add `ENFORCEMENT: blocking` at the top of the file to opt the rule into REQUEST CHANGES verdicts; default is advisory.

#### Out of scope (v1)

- **Per-team / per-project handbook overrides.** Still framework-level only — handbooks travel with the ops fork (and the private layer for split-portfolio adopters). File a separate ticket if multi-team adopters need this.
- **Encryption on top of gitignore for the private custom dirs.** They're inside a private GitHub repo; the gitignore on the public fork is the boundary.
- **Distribution to other organisations.** Custom skills + handbooks are private to one org by design — sharing across orgs is what the public framework + handbooks layer is for.
- **A `/custom-skill` authoring helper.** Manual `cp framework-skill custom-skills/...` + edit is fine for v1.
- **Multi-version handbook conflict resolution.** Operator's prose responsibility.

### Centralised agent routing — `agent-routing.yaml`

ApexYard ships 24 Claude Code sub-agents (19 role-derived personas + 5 utility agents — Rex, Hakim, Munir, Tariq, Idris). The framework picks sensible per-agent model defaults from the matrix in [AgDR-0050 § Axis 2](agdr/AgDR-0050-agent-runtime-overhaul.md) (Opus for depth + reasoning, Sonnet for the majority + tool-use-heavy, Haiku for checklist-shaped repeatable work). Adopters override those defaults — switch the QA Engineer to Sonnet for higher-recall AC runs, route the Data Analyst through a local Ollama endpoint, raise the Pen Tester's invocation timeout — via a single YAML file kept in the private portfolio repo.

This sibling pattern to **Custom templates** (path-mirroring overrides; see AgDR-0023) and **Custom skills + handbooks** above puts every adopter-specific routing choice in one centrally-edited surface, source-controlled in the private repo, never leaking to the public fork.

#### File location

| Mode | Path | Visibility |
| --- | --- | --- |
| **Split-portfolio (v2)** | `<private_repo>/agent-routing.yaml` | Private — committed to the sibling repo, resolved via `.portfolio.agent_routing` in `.apexyard/project-config.json` |
| **Single-fork** | `<fork>/agent-routing.yaml` | Local — gitignored by the framework (`/agent-routing.yaml` in `.gitignore`), never pushed to the public fork |

Seed from the framework example. **Split-portfolio adopters get this done automatically by `/setup --split-portfolio`** (#351 PR 3) — the skill copies the example into the private repo as part of Step 5 (private-repo init). Single-fork adopters do the `cp` manually when they want to start customising; the framework deliberately doesn't auto-seed for single-fork because an empty override file accumulating in the fork root before any overrides exist is more ceremony than value.

```bash
# Split-portfolio — `/setup --split-portfolio` does this for you. Manual fallback:
cp ~/ops/apexyard/agent-routing.yaml.example ~/ops/apexyard-portfolio/agent-routing.yaml

# Single-fork — always manual (and only when you're ready to customise):
cp ~/ops/apexyard/agent-routing.yaml.example ~/ops/apexyard/agent-routing.yaml
```

Edit the file; the schema is self-documented inside the example. An empty `agents: {}` block is identical to "no file" — adopters get framework defaults out-of-box.

#### Schema (per-entry fields)

The full reference lives in [`agent-routing.yaml.example`](../agent-routing.yaml.example). One-line summary per field:

| Field | Required? | Purpose |
| --- | --- | --- |
| `model` | yes (for an override entry) | Model specifier — `opus` / `sonnet` / `haiku` / `ollama/<spec>` / `bedrock/<spec>` |
| `endpoint` | no | Alternative inference endpoint (e.g. LiteLLM proxy URL); session-scoped — sets `ANTHROPIC_BASE_URL` at SessionStart |
| `env` | no | Map of environment variables for the agent's invocations; supports `$VAR_NAME` refs |
| `timeout_seconds` | no | Override the framework default invocation timeout |

Worked examples (single-agent override, multiple overrides, local routing via Ollama + LiteLLM, Bedrock with AWS env, timeout override) are in the example file.

#### Local-model routing — Claude default, local opt-in

**Claude is the framework default for every agent.** The schema supports routing through a LiteLLM proxy fronting Ollama (or any Anthropic-compatible endpoint), but the framework does **NOT** ship a recommended local model. Hardware varies too much across adopter machines — an Apple Silicon M2 Max with 32 GB unified memory runs different models well than a Linux box with a 12 GB GPU than a CPU-only laptop. Pre-loading a "framework-recommended" entry would mislead more adopters than it'd help.

The pattern lives in `agent-routing.yaml.example` Example C as a commented-out template with four candidate models annotated by their RAM-at-load cost (`qwen2.5-coder:14b` ~10 GB, `llama3.1:8b` ~6 GB, `deepseek-coder-v2:16b` ~12 GB, `mistral-small3:24b` ~18 GB at q4 quantization). Adopters who want local routing:

1. Pick a model that fits the machine (Ollama's `ollama run <model>` warm-load time is a good rough gauge — anything > 10s suggests the model is too big).
2. Uncomment the chosen entry in their `agent-routing.yaml` (private repo for split-portfolio mode, gitignored fork file for single-fork).
3. Start LiteLLM proxy: `litellm --config ~/litellm-config.yaml --port 4000`. `agent-routing.yaml.example`'s Example C uses `http://localhost:4000` as the proxy endpoint by convention.
4. Validate the chosen model against representative workloads (ticket-creation via `/feature`, SQL via Nadia, AC verification via Salim) BEFORE relying on it for production work. Tool-call reliability via LiteLLM's Anthropic-shape translator is the load-bearing risk; treat the first dozen invocations as a smoke test.
5. v1 is **session-scoped** — when the `endpoint:` field is set, ALL agents on that session share the configured `ANTHROPIC_BASE_URL`. Per-agent invocation-env scoping is deferred to v2 (depends on Claude Code surfacing per-invocation env, not on apexyard).

Adopters who want to validate specific models against their machine before committing can use the operator-prep doc at `projects/apexyard/spike-348-prep.md` as a starting checklist (hardware checks, fixture pack for the 3 candidate sub-agents, scoring matrix).

> The `allowed_tools_override` field was advertised in early drafts of this schema but never wired through the parser. Dropped in #358 for v1; the per-agent allowed-tools list in each `.apexyard/agents/<name>.md` frontmatter is the source of truth. To override on a specific fork, edit the agent file directly with a `# routing-config:override <reason>` comment in the YAML frontmatter (same escape-hatch pattern that handles framework-default `model:` overrides).

#### Config-block wiring (split-portfolio v2)

Add the `agent_routing` key to your existing `portfolio:` block alongside the v2 + #243 keys:

```json
{
  "portfolio": {
    "registry":             "../apexyard-portfolio/apexyard.projects.yaml",
    "projects_dir":         "../apexyard-portfolio/projects",
    "ideas_backlog":        "../apexyard-portfolio/projects/ideas-backlog.md",
    "onboarding":           "../apexyard-portfolio/onboarding.yaml",
    "workspace_dir":        "../apexyard-portfolio/workspace",
    "custom_skills_dir":    "../apexyard-portfolio/custom-skills",
    "custom_handbooks_dir": "../apexyard-portfolio/custom-handbooks",
    "agent_routing":        "../apexyard-portfolio/agent-routing.yaml"
  }
}
```

The key is optional — the default resolves to `./agent-routing.yaml` against the ops-fork root. Single-fork adopters can leave it unset and just keep `agent-routing.yaml` at the fork root (gitignored).

The `_lib-portfolio-paths.sh` helper exposes the resolver as `portfolio_agent_routing` (mirrors the shape of `portfolio_registry`, `portfolio_onboarding_path`, etc.); the SessionStart sync hook (see below) uses it to find the file.

#### How the overrides get applied

The `apply-agent-routing.sh` SessionStart hook reads `agent-routing.yaml` on every session start and rewrites the affected `.apexyard/agents/*.md` frontmatter in-place. Adopter routing choices land in the rendered agent files for that session and stay there until the hook re-runs.

Two **drift-prevention guards** (PreToolUse on `git commit *` and `git push *`) catch the rewritten frontmatter before it leaves the local environment so adopter overrides never leak to the public fork:

- **`block-agent-routing-drift.sh`** — fires on staged `.apexyard/agents/*.md` diffs whose `model:` frontmatter no longer matches the framework default. Exits 2 with an explanation; the operator restores the default and re-stages, OR explicitly opts in via the `# routing-config:override <reason>` escape-hatch comment when an intentional framework-default change is the *point* of the commit (rare, framework-PR territory).

Per AgDR-0050 § Axis 4.

#### Wave 2 complete

The 4-PR wave from AgDR-0050 is fully landed: #353 (schema + resolver), #357 (SessionStart sync + drift guards), #363 (`/setup` integration), and #364's bundle alongside this PR (PR 4 — Claude-default + local-as-commented-examples). #348 (the spike that originally gated PR 4) was closed as out-of-scope when the design shifted to "framework ships the pattern, not the recommendation" — hardware variance across adopter machines makes a single recommended local model misleading more often than helpful. Adopters who want to validate specific models against their own hardware can use the operator-prep doc at `projects/apexyard/spike-348-prep.md` as a starting checklist.

#### Out of scope (v1)

- **Mixed remote + local routing on one session.** v1 is single-endpoint per session — all agents on a session share the configured `ANTHROPIC_BASE_URL` or none do. Per-agent invocation env scoping is deferred to v2 (AgDR-0050 § Axis 5 + Risks).
- **Per-task / per-invocation model overrides.** `claude --model <m>` already exists for one-off use; this file is the persistent surface.
- **A web UI / CLI for editing the routing config.** Adopters edit YAML.
- **Auto-detection of local endpoints.** Adopters declare them.
- **Cost dashboards / per-agent usage tracking.** Separate concern; file if needed once running data exists.

Design rationale: [AgDR-0050](agdr/AgDR-0050-agent-runtime-overhaul.md) (axes 3-5). Prior-art for the "adopter customisation layer in the private repo" pattern: [AgDR-0023 — custom-templates override semantics](agdr/AgDR-0023-custom-templates-override-semantics.md). Prior-art for the SessionStart-driven file rewrites that PR 2 will use: [AgDR-0041](agdr/AgDR-0041-sessionstart-v2-anchor-sweep.md).

### Migrating from split-portfolio v1 to v2

If you adopted split-portfolio mode before framework #242, your fork is on the v1 layout: `apexyard.projects.yaml` and `projects/` resolve to the sibling private repo (good), but `onboarding.yaml` and `workspace/` are still in the public fork. The v2 migration moves both to the private repo too, and writes the new `.apexyard-fork` anchor.

**You don't need to run this manually — `/update` detects the v1 layout and offers the migration as a default-yes step during the next upstream sync.** When you run `/update` after pulling framework ≥ #242, you'll see:

```
ApexYard /update detected your fork is in split-portfolio mode (v1 layout):

  - apexyard.projects.yaml     → resolved to a sibling private repo (good)
  - projects/                  → resolved to a sibling private repo (good)
  - onboarding.yaml            → still in this public fork (v1 layout)
  - workspace/                 → still in this public fork (v1 layout)

Split-portfolio v2 (introduced in framework #242) moves onboarding.yaml
AND workspace/ to the private sibling repo too, so the public fork holds
ONLY framework files + your customisations to skills/hooks/rules.

Migrate now? This will:
  - Copy onboarding.yaml to the sibling private repo (sibling becomes canonical;
    public fork keeps a gitignored snapshot for legacy tooling)
  - Move workspace/<name>/ contents to the sibling private repo
  - Add gitignore entries for both in the public fork
  - Write a .apexyard-fork marker (the v2 ops-fork anchor)
  - Add portfolio.{onboarding,workspace_dir} keys to .apexyard/project-config.json

Per-file-class semantics: onboarding.yaml is COPIED (small text file, sibling is
the canonical source of truth); workspace/ is MOVED (size constraint — clones
are potentially gigabytes, doubling disk usage makes no sense). Idempotent — if
interrupted, re-run. Per AgDR-0021 § H.

[Y / n / dry-run — show commands, don't execute]
```

The migration is **per-file-class confirmable** (copy `onboarding.yaml`? Y/N; move `workspace/`? Y/N), so you can defer one and migrate the other. It's also **idempotent** — if you re-run `/update` later, the migration is a no-op. The mixed copy / move semantics are deliberate — see [AgDR-0021 § H](agdr/AgDR-0021-split-portfolio-v2-path-resolution.md) for the rationale (small text files like `onboarding.yaml` benefit from a public-fork snapshot for legacy tooling; large directories like `workspace/` would waste disk if duplicated).

`/update --dry-run` walks through the migration steps without executing them, useful for previewing what would change.

The skill **does not commit** — staging is the contract; you own both the public-fork commit AND the sibling-repo commit. After accepting the migration:

```bash
# Public fork — review what's staged + the marker + config-block additions
git diff --cached
git commit -m "chore: migrate to split-portfolio v2"

# Private sibling repo — onboarding + workspace landed here
cd ../apexyard-portfolio
git status        # see the moved files
git add onboarding.yaml workspace
git commit -m "chore: receive onboarding + workspace from public fork (split-portfolio v2)"
```

**What if you want to migrate by hand?** Run the same steps the `/update` skill runs (per AgDR-0021 § H — `onboarding.yaml` uses **copy** semantics, `workspace/` uses **move**):

```bash
cd ~/ops/apexyard

SIBLING=../apexyard-portfolio   # adjust to your sibling-dir name

# Copy onboarding.yaml — sibling becomes canonical source of truth; public
# fork keeps a gitignored snapshot for legacy tooling (per AgDR-0021 § H).
cp -p onboarding.yaml "$SIBLING/onboarding.yaml"
git rm --cached onboarding.yaml 2>/dev/null || true

# Move workspace/<name>/ contents — size constraint (clones are potentially
# gigabytes; duplicating wastes disk).
mkdir -p "$SIBLING/workspace"
for entry in workspace/*; do
  [ -e "$entry" ] || continue
  name=$(basename "$entry")
  [ "$name" = "README.md" ] && continue   # framework file, stays
  mv "$entry" "$SIBLING/workspace/$name"
done

# Update .gitignore in the public fork (must include onboarding.yaml so the
# kept-but-gitignored snapshot doesn't get committed alongside customisations).
cat >> .gitignore <<'IGNORE'

# Split-portfolio v2 (framework ≥ #242)
onboarding.yaml
workspace
IGNORE

# Write the v2 anchor
echo "# This file marks the directory as an ApexYard ops fork (split-portfolio v2)." > .apexyard-fork

# Update the config block — add the v2 keys
jq --arg onb "$SIBLING/onboarding.yaml" \
   --arg ws  "$SIBLING/workspace" \
   '.portfolio.onboarding = (.portfolio.onboarding // $onb)
    | .portfolio.workspace_dir = (.portfolio.workspace_dir // $ws)' \
   .apexyard/project-config.json > /tmp/pc.json && mv /tmp/pc.json .apexyard/project-config.json

git add .gitignore .apexyard-fork .apexyard/project-config.json
```

### Migrating from single-fork to split-portfolio

If you've already started in single-fork mode and pushed private project names to your public fork, run the **`/split-portfolio`** skill (introduced #146) — it automates the full destructive recovery flow with explicit operator-confirmation gates at each step:

```
/split-portfolio              # full migration — 10 steps, all gated
/split-portfolio --verify     # read-only state report, no destructive ops
/split-portfolio --dry-run    # walk through each step printing the commands, execute none
```

The skill performs:

1. Push the current public fork's main to a backup branch (`backup-pre-rewrite`) for safety.
2. Reset main to the commit before the bulk-handover (or use `git filter-repo` for older history) to remove the registry + `projects/` from public main.
3. Force-push main with `--force-with-lease`.
4. Create the private portfolio repo and push the extracted registry + `projects/` content into it.
5. Write the `portfolio:` config block in `.apexyard/project-config.json` pointing at the sibling repo (or symlinks if you'd rather — your choice, prompted at the relevant step).
6. **Redact any GitHub Issue or Pull Request bodies** that named the projects — surfaces the timeline-API survival caveat explicitly so you don't have false confidence.
7. Offer to delete the backup branch after a soak window (default: keep for 7 days).

If you can't run the skill (e.g. you're on a framework version that predates it), the manual recipe above still works step-by-step — see `docs/multi-project.md` history before #146 for the original step list.

---

## Directory layout

```
your-org/apexyard/                ← your fork, cloned locally (the "ops repo")
├── CLAUDE.md                      ← entry point Claude Code reads first
├── onboarding.yaml                ← company + team + stack config
├── apexyard.projects.yaml        ← the portfolio registry
│
├── .apexyard/                       ← shared rules, skills, hooks, agents
│   ├── rules/
│   ├── skills/
│   ├── hooks/
│   ├── agents/
│   └── settings.json
│
├── roles/                         ← 19 role definitions, upstream from apexyard
│   ├── engineering/
│   ├── product/
│   ├── design/
│   ├── security/
│   └── data/
│
├── workflows/                     ← SDLC, code review, deployment
├── templates/                     ← PRD, tech design, ADR, AgDR
├── golden-paths/                  ← reusable CI pipelines
├── site/                          ← the apexyard landing page (feel free to delete or replace)
│
├── workspace/                     ← LIVE WORKING COPIES (gitignored)
│   ├── README.md
│   ├── example-app/               ← `git clone`d, has its own .git/
│   ├── billing-api/
│   └── marketing-site/
│
├── projects/                      ← APEXYARD DOCS PER PROJECT (committed)
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
- **`projects/<name>/`** is where ApexYard docs about the project live. It's committed to your fork alongside the registry. Roadmaps, handover assessments, stakeholder updates all live here.

The test for *"where does this doc go?"* is **"would I want this to follow the code if the project was spun out tomorrow?"** If yes → put it in the project's own repo (i.e. inside `workspace/<name>/docs/`). If no → put it in `projects/<name>/` in your fork.

---

## How skills behave

Every portfolio skill reads `apexyard.projects.yaml` and iterates the registry.

| Skill | Behaviour |
| ------- | ----------- |
| `/projects` | Reads the registry, shows one row per project with status, branch, open PRs, open issues |
| `/status` | Same as `/projects` but with git + CI snapshots per project, separated by headers |
| `/inbox` | Aggregates PRs, issues, and comments needing your attention across every registered project |
| `/tasks` | Aggregated, scored, and sorted task list across the portfolio |
| `/idea` | Appends to `projects/ideas-backlog.md` at the fork root (one shared backlog for all projects) |
| `/roadmap` | Reads `projects/<name>/roadmap.md`; asks which project if ambiguous |
| `/stakeholder-update` | Portfolio rollup with a section per project |
| `/handover` | Writes to `projects/<name>/handover-assessment.md`, appends the project to the registry, scores **harnessability** across 5 codebase dimensions (type safety, module boundaries, framework opinionation, test coverage signal, lint baseline) — with a `low`-verdict warning about Rex blocking-handbook false positives so adopters know whether to run handbooks in advisory-only mode (see AgDR-0042). **Step 7.5** surfaces the assessment's derived Next Steps inline and offers to file each as a tracker ticket (per-item y/n; auto-routes by item shape to `/feature` / `/task` / `/bug`; default `/task`; each filed ticket carries a `_Source: handover deep-dive on YYYY-MM-DD_` back-link to the assessment) — closes the recommendation-rot loop where static prose in the assessment used to be hand-translated to tickets one at a time. **Step 8** offers (default-no) to clone the project into `workspace/<name>/` for an LSP-aware deep-dive follow-up (`/code-review`, `/threat-model`, `/security-review`). The clone offer surfaces the cost (disk, gitignored status, `ENABLE_LSP_TOOL=1` + per-language plugin install) explicitly. |
| `/extract-features` | Scans a project's codebase across six discovery axes (HTTP routes, data models, async jobs, test names, UI screens, documented features) and writes a consolidated Feature Inventory at `projects/<name>/feature-inventory.md`. Pairs with `/handover` as the **greenfield-rewrite path** — `/handover` produces the high-level project assessment, `/extract-features` produces the granular "what we must preserve" catalogue. One-off scan, not a recurring audit; re-runs OFFER (default-no) to overwrite. Opt-in `--with-mockups` flag adds a `## Screens` section with AI-inferred ASCII wireframes per UI screen — boxed layouts, form-field bindings inferred from static analysis, every wireframe carries a mandatory disclaimer header (`> AI-inferred sketch — verify before relying on`). See AgDR-0036 for the trust-contract rationale. |
| `/feature-diagram` | Slice the system by feature — reads one row from `projects/<name>/feature-inventory.md` and emits a Mermaid `flowchart LR` at `projects/<name>/features/<slug>.md` showing the routes / models / jobs / screens that participate in that feature. Sibling to `/c4` (system topology) and `/dfd` (data flows) — different lens (per-feature slice) on the same codebase. Inventory is a hard dependency: run `/extract-features` first. Re-runs prompt to overwrite; `--force` bypasses. See AgDR-0035. |
| `/process` | Anchor-scoped scan across **seven** process-discovery axes (explicit workflow definitions, queue/job chains, cron triggers, state-column transitions, API choreography, existing BPMN/Mermaid, documented steps) — optionally cross-repo via `apexyard.projects.yaml`. Interviews only on the gaps the code couldn't answer, then emits a lint-clean BPMN 2.0 file at `projects/<name>/processes/<slug>.bpmn`. Sibling to `/c4` (static system topology) and `/extract-features` (exhaustive feature catalogue) — same read-first-then-ask shape, BPMN as the output. Requires Node + npm for `bpmn-auto-layout` + `bpmnlint`; falls back to bare BPMN when Node is missing. |
| `/c4` | Reads a project's codebase and writes filled-in C4 L1 + L2 Mermaid diagrams (location depends on invocation context — see `.apexyard/skills/c4/SKILL.md`) |
| `/tech-vision` | Interactive section-by-section author for the **technical / architecture** vision template (named `tech-vision` to disambiguate from product / company vision). Walks the operator through Scope, Principles, Target-state C4 L1, Current vs Target gap table, multi-quarter Migration path, explicit Anti-scope ("things we explicitly chose NOT to build"), and Review cadence — then writes `projects/<name>/architecture/vision.md`. Resolves the template via `portfolio_resolve_template architecture/vision.md` so adopters with `<private_repo>/custom-templates/architecture/vision.md` see their shape. Re-runs OFFER (default-no) to overwrite; refresh mode preserves existing content as defaults for a quarterly review. Markdown-only output — Mermaid C4 block renders inline on GitHub, same as `/c4` / `/dfd`. See AgDR-0028. |
| `/pdf` | Convert any framework-generated doc (markdown, HTML, BPMN) to PDF. Asks where the PDF should land via a 4-option prompt: `workspace/<name>/docs/` (travels with the code), `projects/<name>/pdfs/` (ApexYard's view), a custom path, or "keep next to source". Converter dispatch is pandoc → md-to-pdf → wkhtmltopdf for markdown/HTML, and bpmn-to-image → SVG → pandoc for BPMN. Graceful-degrades when no converter is installed (exit 3 + advisory). See AgDR-0034. |
| `/codify-rule` | Turn a human (or Copilot, or any second-pass) review comment that caught a Rex-miss into a draft handbook entry. Resolves the source PR (current branch's open PR, `--pr <N>`, or a full GitHub PR-comment URL), prompts for the comment text + file:line context, routes to the right bucket (domain / architecture / general / language), and gates the full draft on Y/edit/no before any file is written. Every entry carries a `_Source: PR #N comment by @author on YYYY-MM-DD_` footer for traceability. Defaults to advisory enforcement; `--blocking` flag opts in to `ENFORCEMENT: blocking`. Domain bucket pre-populates a `paths:` frontmatter glob from the file:line context for the operator to refine. For split-portfolio adopters with a configured `custom_handbooks_dir`, the skill offers to land the entry in the private layer instead of the public `handbooks/`. Stage 2 of #293 (Rex domain-aware handbooks); sibling to the future `/enrich-domain` skill (Stage 3). See AgDR-0040. |
| `/geo-audit` | LLM/agent discoverability audit (GEO + AEO) — six check buckets (Discovery / Capability-signaling / Content-format / Token-economics / Analytics / UX) covering `llms.txt`, `llms-full.txt`, AI-crawler directives in `robots.txt`, `AGENTS.md`, `skill.md` capability manifest, JSON-LD citation grounding (`author` / `dateModified` / `datePublished` / `publisher`), snippet-extractable Q&A shape, markdown alternates, first-500-tokens lead, prompt-injection hygiene, per-page token-count thresholds, and an AI-traffic fingerprint advisory. Covers GEO (LLM citations) + AEO (coding-agent consumption). Sibling to `/seo-audit`; `/launch-check` fans out to both at milestone boundaries. v1 AI-crawler list (12 entries: GPTBot, ChatGPT-User, OAI-SearchBot, ClaudeBot, Claude-Web, anthropic-ai, Google-Extended, PerplexityBot, CCBot, Bytespider, Applebot-Extended, cohere-ai) lives at `.apexyard/registries/ai-crawlers.json`. The audit's `skill.md` capability-manifest check is the upstream GEO/AEO convention — **distinct from Claude Code's `SKILL.md`** slash-command spec; AgDR-0043 documents the naming clash. Auto-PASS for non-web projects (APIs, CLIs, libraries). Advisory posture — severity ceiling is `high`, not `critical`. Persists via `_lib-audit-history.sh` (AgDR-0019). Originally shipped as `/generative-engine-audit` (PR #315); renamed in #334. See AgDR-0043. |

Skills that aren't portfolio-aware (`/decide`, `/write-spec`, `/code-review`, `/security-review`, `/audit-deps`) operate on the current working directory — `cd workspace/<name>/` first if you want them to run against a specific project's code.

---

## Architecture diagrams

Every managed project should have at least a **C4 Level 1 (System Context)** diagram, and ideally a **Level 2 (Container)** one. Diagrams are written as Mermaid inside Markdown files — GitHub renders them inline, zero build step.

Templates:

- `templates/architecture/c4-context.md` — L1, system + external actors
- `templates/architecture/c4-container.md` — L2, deployable units inside the system boundary

Where to put the diagrams (same split as every other kind of doc — "would this follow the code if the project spun out?"):

| Scope | Location |
| ------- | ---------- |
| Framework-wide (ApexYard itself) | `docs/architecture/` in the ops fork |
| ApexYard's view of a managed project | `projects/<name>/architecture/` in the ops fork |
| Internal to a project's own repo | `docs/architecture/` in that project's repo (via `workspace/<name>/docs/architecture/`) |

ApexYard dogfoods its own convention — see `docs/architecture/apexyard-context.md` and `apexyard-container.md` for a worked example.

Decision rationale (tool choice — Mermaid C4 over Structurizr DSL / PlantUML / D2): [`docs/agdr/AgDR-0003-mermaid-c4-for-diagrams.md`](agdr/AgDR-0003-mermaid-c4-for-diagrams.md).

### PDF exports follow the same rule

The `/pdf` skill (introduced in framework #284) converts framework-generated docs (markdown / HTML / BPMN) to PDF for sharing with non-technical stakeholders, board members, customers, or auditors. At export time it **asks** where the PDF should land — using exactly the "would it follow the code if the project spun out?" test from the table above:

| If YES (travels with the code) | If NO (ApexYard's view) |
|---|---|
| `workspace/<name>/docs/<stem>.pdf` | `projects/<name>/pdfs/<stem>.pdf` |
| Examples: API spec PDF, deployment runbook PDF, internal sequence diagram | Examples: handover assessment, stakeholder update, audit verdict, multi-quarter roadmap snapshot |

The prompt also offers a custom-path slot and a "keep next to source" slot for one-off shares. Defaults can be locked via the `pdf.default_destination` key in `.apexyard/project-config.json` — see `.apexyard/skills/pdf/SKILL.md` and [`docs/agdr/AgDR-0034-pdf-export-and-converter-dispatch.md`](agdr/AgDR-0034-pdf-export-and-converter-dispatch.md).

`/pdf` graceful-degrades when no PDF converter is installed — same shape as `/process` (bpmnlint) and `/c4` (Mermaid lint): exit 3 with an advisory naming each install option, so adopters who never need PDFs still pay zero install cost.

---

## Daily workflow

A typical morning as a CTO / Chief of Staff using apexyard:

1. **`cd ~/apexyard`** — into your fork
2. **`apexyard status`** (or `/status --briefing` inside Claude Code) — 4-line "where am I" briefing: active workspace, active ticket, branch, role. Covers the orient-yourself question in one paragraph.
3. **`/inbox`** — see everything waiting on you across every managed project
4. **`/status`** — full snapshot of git + CI health for each project (verbose form when you want the per-project breakdown)
5. Pick a ticket, **`cd workspace/<project>/`**, pick up the ticket as the appropriate role (see [`.apexyard/rules/role-triggers.md`](../.apexyard/rules/role-triggers.md))
6. Work the ticket — the role file drives behaviour, the lifecycle demo in the hero of the landing site walks through the full flow
7. Back at the fork root, **`/stakeholder-update weekly`** on Fridays to generate the summary

### `apexyard status` — the CLI briefing

`bin/apexyard` is a small bash shim that exposes the briefing at the shell. Install once by symlinking it onto your PATH:

```bash
ln -s "$(pwd)/bin/apexyard" ~/.local/bin/apexyard
```

Then from anywhere inside the fork or any `workspace/<name>/` clone:

```bash
$ apexyard status
Active workspace:  example-app
Active ticket:     #42 — Add CSV export
Branch:            feature/GH-42-csv-export
Role set:          backend
```

The same output appears when you run `/status --briefing` (or `/status -b`) inside Claude Code. The four fields all infer themselves: workspace from cwd, ticket from the per-project marker (`<ops_root>/.apexyard/session/tickets/<name>`) or the ops fallback (`<ops_root>/.apexyard/session/current-ticket`), branch from `git branch --show-current`, role from the active ticket's labels. Where any of those is unknown, the briefing prints an explicit `(none)` / `(unknown)` / `<none — inferred per task>` placeholder so the four-line shape is constant regardless of state.

Default `/status` (no flags) still produces the long per-project breakdown — `--briefing` only opts into the compact form.

### LSP-aware skills inside a workspace

If you've enabled the optional LSP tool (`ENABLE_LSP_TOOL=1` + a per-language plugin — see [`getting-started.md` § "Optional: LSP-aware code navigation"](getting-started.md#optional-lsp-aware-code-navigation)), code-aware skills like `/code-review`, `/threat-model`, and `/security-review` use semantic-index queries instead of grep when they run inside a cloned `workspace/<name>/`. The same skills fall back to grep + Read transparently when LSP is absent — there's no new failure mode, only optional speed.

Cross-project portfolio skills (`/inbox`, `/tasks`, `/stakeholder-update`) walk the whole registry and stay on grep regardless, because no single LSP server has the full multi-repo view.

---

## Upgrades — pulling from upstream

`upstream/main` is **release-only** (since v1.2.0 — see [AgDR-0007](agdr/AgDR-0007-release-cut-branch-model.md)). The framework repo cuts releases via `dev → main` PRs with semver tags; adopters pull tagged releases via `/update`. You will not see WIP commits on `upstream/main` — only the curated release stream.

> **Note for fork owners:** the dev/main split applies to `me2resh/apexyard` only. Your ops fork stays trunk-based on `main` (your daily work merges directly), and so do all the projects you manage under it. Don't cargo-cult the dev/main pattern into managed projects; they have no downstream consumers and don't need it.

### How you know it's time

On every Claude Code session start, the `check-upstream-drift.sh` hook runs `git fetch upstream` (cached to once per 10 minutes) and prints a one-line banner if your fork is behind:

```
ApexYard: 12 commits behind upstream/main. Run /update to sync.
```

Silent if up-to-date, silent on network failure, silent if no `upstream` remote is configured. No extra startup cost when there's nothing to say.

### Syncing

Every few weeks, pull the latest apexyard improvements into your fork. The easy path is the `/update` skill:

```
/update              # preview + merge-based sync on a sync branch (default)
/update --rebase     # rebase-based sync (cleaner linear history)
/update --dry-run    # preview only, no state change
```

`/update` does the work of the manual flow below: fetches `upstream`, previews the commit delta, creates a sync branch (because `block-main-push.sh` forbids direct pushes to `main`), merges or rebases, walks through any conflicts with per-file options, surfaces any **deprecated config keys** in your `.apexyard/project-config.json` that no longer exist in upstream defaults (advisory y/n/s offer — see step 8 of the skill), and leaves the branch ready to push as a PR. See `.apexyard/skills/update/SKILL.md` for the full process.

> **Pre-release testing (`/update --from-dev`).** A hidden `--from-dev` flag pulls from `upstream/dev` instead of the latest tagged release on `upstream/main`. Intended for the framework maintainer testing pre-release work on a separate machine, and for adopters who explicitly want to validate an upcoming framework change before the release tag is cut. **Not a supported general-adopter path** — the adopter contract is tagged releases from `upstream/main` (see [AgDR-0007](agdr/AgDR-0007-release-cut-branch-model.md)). Prints a `⚠ PRE-RELEASE SYNC` banner before any state mutation, uses the same sync-branch + conflict-resolution flow, and lands on a `chore/sync-upstream-dev` branch. Revert with `git reset --hard origin/main` if needed. See `.apexyard/skills/update/SKILL.md` § Options for details.

If you prefer the raw commands:

```bash
cd ~/apexyard

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
gh pr create --title "chore: sync ops fork with upstream apexyard"
```

Files you're most likely to customise:

- `onboarding.yaml` — always yours, never upstream
- `apexyard.projects.yaml` — always yours
- `projects/<name>/` — always yours
- `site/index.html` — delete or replace with your own landing page
- Role files in `roles/` — usually upstream, but feel free to edit for your team's voice

Files that stay close to upstream (merge cleanly most of the time):

- `.apexyard/hooks/` — shell scripts
- `.apexyard/rules/` — modular rule files
- `.apexyard/agents/` — sub-agent definitions
- `workflows/` — SDLC, code review, deployment
- `templates/` — PRD, tech design, ADR, AgDR
- `golden-paths/` — reusable CI pipelines

---

## Trade-offs

### Pros of the fork-as-ops-repo model

- **One repo to rule them all** — the fork IS the ops repo. No nested installs, no symlinks.
- **Brand visible** — if you keep the fork named `apexyard`, anyone looking at your org sees you're running the stack.
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

**Can I have two ops repos?** Yes. Some teams split by domain (e.g. one ops repo for product, one for platform). Each ops repo is an independent fork of apexyard with its own registry.

**Can a project be in two registries?** Technically yes, but don't. It defeats the "single source of truth" benefit and creates conflicts in `projects/<name>/`. Pick one ops repo per project.

**Do I need to clone every project locally?** No. The `workspace` field in the registry is optional. Skills will use GitHub-only data and mark git fields as `(not cloned)` for projects without a local clone.

**Does `/decide` write AgDRs to the fork or the project repo?** The project repo. AgDRs are tied to commits, so they live with the code. `/decide` always writes to `{cwd}/docs/agdr/`, which means you need to `cd workspace/<name>/` first.

**Does the registry support globs?** No. It's an explicit list. If you want all repos in an org, use `gh repo list` to generate the file once and commit the result — but you should still curate it.

**Can I use this with Linear / Jira / etc.?** Yes — and the framework's mechanical hooks (`/start-ticket`, `validate-pr-create.sh`, `verify-commit-refs.sh`, `validate-branch-name.sh`) verify ticket existence against your tracker via the `tracker` config block. The default `kind = gh` calls `gh issue view`; swap it for `linear` / `jira` / `asana` / `custom` to dispatch a different CLI. See AgDR-0033 and `.apexyard/hooks/_lib-tracker.sh`. Example override in `.apexyard/project-config.json`:

```json
{
  "tracker": {
    "kind": "linear",
    "view_command": "linear issue view {id} --json",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
```

For Jira, point at the [ankitpokhrel/jira-cli](https://github.com/ankitpokhrel/jira-cli) raw-JSON output:

```json
{
  "tracker": {
    "kind": "jira",
    "view_command": "jira issue view {id} --raw",
    "id_pattern": "^[A-Z]+-[0-9]+$"
  }
}
```

For Asana (per-task lookup by GID):

```json
{
  "tracker": {
    "kind": "asana",
    "view_command": "asana task get {id} --json",
    "id_pattern": "^[0-9]+$"
  }
}
```

If your tracker has no CLI, use `kind: "custom"` with a `view_command` that calls `curl` and a `normalise_jq` filter to map the response into `{state, title, url, labels}`. If you want to disable existence verification entirely (rare — accepted gap when no CLI exists), set `kind: "none"` — the hooks fall back to shape-only validation via `tracker.id_pattern`. The registry-level `ticket_prefix` field is still respected per-project for the `/start-ticket` branch-suggestion step.

**What if I only have one repo?** Fork apexyard anyway and register that one repo. The skills work the same way. When you add a second project, just append to the registry — no migration, no re-setup.

**Can I delete the landing page (`site/`)?** Yes — it's the apexyard marketing site. Feel free to delete, replace, or leave it in place. It doesn't affect the rest of the stack.

**Can I rename my fork?** Yes. GitHub handles rename redirects cleanly. Your local clone will need `git remote set-url origin` after the rename.

---

## Related docs

- `apexyard.projects.yaml.example` — the registry schema
- `workspace/README.md` — the live working copies convention
- `projects/README.md` — the per-project docs convention
- `onboarding.yaml` — company + team + stack config
- `.apexyard/rules/role-triggers.md` — when to activate which role
- `.apexyard/skills/projects/SKILL.md` — the `/projects` skill spec
- `.apexyard/skills/handover/SKILL.md` — the `/handover` skill spec

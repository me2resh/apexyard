<p align="center">
  <a href="https://apexyard.ai"><img src="https://apexyard.ai/brand/apexyard-avatar-512.png" alt="ApexYard" width="88"></a>
</p>

<h1 align="center">ApexYard</h1>

<p align="center">
  <strong>Take agent-built code the last mile — safely to production.</strong>
</p>

<p align="center">
  <a href="https://github.com/me2resh/apexyard/releases"><img src="https://img.shields.io/github/v/release/me2resh/apexyard?color=2F6DF6&label=release" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://claude.com/claude-code"><img src="https://img.shields.io/badge/built%20for-Claude%20Code-8A63D2" alt="Built for Claude Code"></a>
  <a href="https://apexyard.ai"><img src="https://img.shields.io/badge/site-apexyard.ai-2F6DF6" alt="Site"></a>
  <a href="https://github.com/me2resh/apexyard/stargazers"><img src="https://img.shields.io/github/stars/me2resh/apexyard?style=social" alt="Stars"></a>
</p>

## AI can build quickly. Shipping safely needs a system.

AI can produce a working prototype in a weekend. Teams still need a way to
track decisions, review changes, run checks, and approve a release.

**ApexYard provides that system.** Every change starts with a ticket. An
independent reviewer checks the change. A merge gate stays closed until a
named human approves the exact commit.

ApexYard is a multi-project **ops repo**. You fork it, register your projects,
and manage the portfolio from one place. Shared rules, project records, and
shell hooks keep the workflow consistent.

Claude Code is the default driver. The rules, hooks, and templates are plain
Markdown and shell, so you can use another coding tool through an adapter.
There is no service to run and no hosted lock-in.

The workflow has been used with TypeScript and AWS Lambda backends, Next.js
apps, Chrome extensions, and native Swift macOS apps.

## What makes it different

| Area | Without ApexYard | With ApexYard |
|---|---|---|
| Code review | Ad-hoc prompts | Rex reviews every pull request. |
| Technical decisions | Lost in chat | Agent Decision Records preserve them. |
| Quality gates | Manual memory | Shell hooks block unsafe actions. |
| Merge approval | Informal “LGTM” | Rex and a named human approve the exact commit. |
| Database migrations | High-risk edits | A migration ticket and rollback plan are required. |
| Architecture | Scattered notes | C4 templates and the `/c4` skill create a shared model. |
| Portfolio view | Several GitHub tabs | `/inbox`, `/status`, and `/tasks` read one registry. |
| Upstream updates | Easy to forget | `/update` reports drift and guides the sync. |
| Roles | Repeated context | Role files activate from clear triggers. |
| Onboarding | Manual setup | `/setup` collects the required configuration. |

## What's inside

ApexYard is a set of plain-text files. Claude Code reads them from the repo
root. No runtime or service is required.

- **20 roles** across 6 departments (engineering, product, design, security, data, architecture) that activate on triggers
- **49 shell hooks** that mechanically enforce the SDLC — ticket-first edits, a two-marker merge gate, migration gates, secrets scanning, and more
- **66 slash-command skills** — from `/setup` and `/handover` to `/decide`, `/code-review`, `/migration`, and `/launch-check`
- **23 sub-agents** — Rex (code review), Hakim (security), Tariq (design review), plus the department personas
- **18 rule files**, workflow docs, and document templates (PRD, tech design, ADR, AgDR, C4 diagrams)

**See [`docs/whats-inside.md`](docs/whats-inside.md) for the full directory and component list.**

> **Marketing site:** the site that was previously bundled here has moved to its own repo ([me2resh/apexyard-site](https://github.com/me2resh/apexyard-site)) and is deployed independently at [apexyard.ai](https://apexyard.ai).
>
> **Built for Claude Code first.** opencode, pi, and Codex use the same rules through small adapters. Cursor has partial support. See [Using another AI coding tool?](#using-another-ai-coding-tool).
>
> **For AI coding agents:** `AGENTS.md` is the universal entry document for tools that do not load `CLAUDE.md`. See [`docs/harnesses/pi.md`](docs/harnesses/pi.md).

## Quick Start — fork and go

ApexYard governs a **portfolio of repos** as one organisation. Fork and clone
the repository. Use that fork as your ops repo. Register each project you want
to manage. The fork is the ops repo, so no nested installation is needed.

> **Using opencode, pi, or Codex?** Steps 1–3 use plain `git` and `gh`. Install
> your tool's adapter before steps 4–6. Each step also gives a manual file
> option. The enforced rules are the same in both paths.

### 1. Star + Fork on GitHub

Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard).
Star it, then fork it into your organisation. Keep the name `apexyard`, or use
a name such as `your-org/ops`.

### 2. Clone your fork locally

```bash
gh repo clone your-org/apexyard
cd apexyard
```

Or with plain git:

```bash
git clone https://github.com/your-org/apexyard.git
cd apexyard
```

### 3. Add `upstream` for future updates

```bash
git remote add upstream https://github.com/me2resh/apexyard.git
```

Later, run **`/update`** to bring upstream changes into your fork. The skill
previews the diff, uses a sync branch, and guides any version migrations.

### 4. Configure the framework — run `/setup`

Run **`/setup`** in Claude Code. The skill asks about your company, team,
technology, and quality bar. It shows the proposed defaults before it writes
the configuration.

```text
/setup
```

Your real config lives in the **gitignored** `onboarding.yaml`. It stays local.
`/setup` copies the tracked `onboarding.example.yaml` placeholder and fills it
in. A commit-time guard blocks the real file if you try to add it.

No `/setup` on your tool? Copy the example and fill it in by hand:
`cp onboarding.example.yaml onboarding.yaml`. The gates read the file, not the
skill.

### 5. Register your projects — run `/handover`

Projects join the portfolio through a skill. For each repo you want to manage:

```text
/handover <repo-url-or-local-path>
```

**`/handover`** clones the repo, scores five harnessability dimensions, seeds
the project docs, and **registers the repo in `apexyard.projects.yaml`**. It
creates the registry on first use. `/setup` can register your first project.

The registry it maintains looks like this — you rarely touch it by hand:

```yaml
version: 1
projects:
  - name: example-app
    repo: your-org/example-app
    docs: projects/example-app
    status: active
```

Register a single repo too. The portfolio skills (`/projects`, `/inbox`, and
`/status`) read the same registry. No `/handover` on your tool? Copy
`apexyard.projects.yaml.example` and add the repos by hand.

### 6. Start working

```
/projects          # list managed projects and status
/inbox             # show PRs, issues, and comments that need attention
/status            # show the git and CI state for each project
/decide            # record a technical decision
```

Hooks run on `git` and `gh` commands. Portfolio skills read the registry. Run
`/code-review <pr>` to invoke the Code Reviewer agent.

Full setup guide with directory layout, daily workflow, and FAQ: [`docs/multi-project.md`](docs/multi-project.md).

Keeping a fork current — upgrade in place, when to re-fork instead, and how to preserve your portfolio data either way: [`docs/upgrading.md`](docs/upgrading.md).

## Using another AI coding tool?

**ApexYard was built for Claude Code.** Its slash commands are native Claude
Code skills. The enforcement layer is plain Bash, so other tools can use the
same rules through an adapter.

As of **2026-07-09**, opencode, pi, and Codex have passed real enforcement
checks. Each tool needs one setting so its commands reach the rules. Cursor has
partial support and is not included in that claim. You can always use the
manual configuration files from Quick Start when a skill is unavailable.

| Tool | Enforces your rules? | Setup | Good to know |
|------|----------------------|-------|--------------|
| **Claude Code** | ✅ **Yes — natively.** Built in; the rules fire on every command. | Nothing to install — `/setup` and you're done. | On Windows, use Git Bash or WSL (the rules are bash). |
| **opencode** | ✅ **Yes — proven.** A real agent's `git add -A` was blocked by the same rule. | `bash bin/install-opencode-adapter.sh` | Run opencode with `--auto` so the agent's command reaches the rule. |
| **pi** | ✅ **Yes — proven.** Same, in a real pi session. | `bash bin/install-pi-adapter.sh` | Run pi with `-a` (auto-approve). pi is deliberately bare-bones — ApexYard is the governance it leaves to you. |
| **Codex** | ✅ **Yes — proven.** Same, in a real Codex session. | `bash bin/sync-codex-adapter.sh` | Codex has to trust the rules once — `/hooks`, a one-off flag, or a user-level install. Details: [`docs/codex-adapter.md`](docs/codex-adapter.md). |
| **Cursor** | 🟡 **Partly.** It blocks the command, but by *failing safe* when its rule-runner errors — not by running our rule. We don't count it as proven. | `bash bin/install-cursor-adapter.sh` | Works in the Cursor **IDE**, not the command-line version. Install is user-level (`~/.cursor/hooks.json`). |

*Under the hood:* your rules stay one set of portable bash scripts, and every tool reads the **same** ones — never a separate copy that can drift out of sync. A daily, credentialed [Conformance CI](docs/conformance-ci.md) job re-verifies each proven harness automatically, so the claims above aren't just one-off manual checks. Full per-tool setup, limits, and how to add a new tool → **[`docs/harnesses/README.md`](docs/harnesses/README.md)**.

## Roles, workflows & templates

ApexYard ships **20 roles** across 6 departments that activate on triggers, a full **SDLC** (Planning → Design → Build → Review → QA → Deploy → Monitor) with a dedicated migration sub-workflow, and reusable **document templates** (PRD, technical design, ADR, AgDR, migration AgDR, C4 diagrams).

The full role roster, workflow detail, and template catalogue live in **[`docs/whats-inside.md`](docs/whats-inside.md)**. The canonical entry point Claude Code reads is [`CLAUDE.md`](CLAUDE.md).

## Show you're governed by ApexYard

Running your repo under ApexYard? Add a badge to its README. Every adopter repo that carries one is a backlink and a bit of social proof — and `/handover` will offer to drop it into the repos it onboards.

**Governed by** — for a repo managed under an ApexYard ops fork:

```markdown
[![Governed by ApexYard](https://img.shields.io/badge/governed_by-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)
```

[![Governed by ApexYard](https://img.shields.io/badge/governed_by-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)

**Built with** — for a project built out through the ApexYard workflow:

```markdown
[![Built with ApexYard](https://img.shields.io/badge/built_with-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)
```

[![Built with ApexYard](https://img.shields.io/badge/built_with-ApexYard-2F6DF6?style=flat-square)](https://github.com/me2resh/apexyard)

## Customization

ApexYard is designed to be customized. Every role, workflow, and template can be modified to fit your team:

1. **Add roles**: Create new `.md` files in `roles/your-department/`
2. **Modify workflows**: Edit files in `workflows/`
3. **Add templates**: Drop new templates in `templates/`
4. **Override anything**: The stack is just markdown files -- edit freely

## Contributing

Contributions are welcome — **start with [CONTRIBUTING.md](CONTRIBUTING.md)** for the full fork → PR → review flow, and open issues with the **Bug report** / **Feature request** templates. All participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). Security issues go through [SECURITY.md](SECURITY.md) (private reporting), not public issues.

ApexYard runs on its own rules, so the flow mirrors any project under ApexYard governance:

1. **File an issue** — open a GitHub issue with the **Bug report** / **Feature request** template. If you run apexyard yourself, the **`/report-apexyard-bug`** and **`/request-apexyard-feature`** skills file it here for you (they target `me2resh/apexyard` — distinct from `/bug` and `/feature`, which file into your *own* managed project).
2. **Start the ticket** — `/start-ticket <number>` so the ticket-first hook lets your code edits through.
3. **Branch + commit** — `{type}/GH-{number}-{short-description}`, conventional commit format (`type(#number): subject`).
4. **Self-check before pushing** — `npm run lint` / markdownlint / shellcheck as applicable; hooks remind you at `git push`.
5. **Open a PR** — title `type(#number): description` + a Glossary section in the body.
6. **Wait for Rex** — the Code Reviewer agent auto-runs on every PR.
7. **Merge requires two markers** — Rex's approval + explicit per-PR human approval via `/approve-merge <pr>`. Plan-level "go" doesn't count.

For larger changes (new skills, rule changes, workflow redesigns), open a discussion or draft PRD first.

## Contributors

Thanks to everyone who contributes code, documentation, bug reports, ideas, and feedback.

<p>
<a href="https://github.com/me2resh" title="me2resh"><img src="https://github.com/me2resh.png?size=100" width="64" height="64" alt="me2resh"></a>
<a href="https://github.com/AbdElrahmaN31" title="AbdElrahmaN31"><img src="https://github.com/AbdElrahmaN31.png?size=100" width="64" height="64" alt="AbdElrahmaN31"></a>
<a href="https://github.com/HishamM1" title="HishamM1"><img src="https://github.com/HishamM1.png?size=100" width="64" height="64" alt="HishamM1"></a>
<a href="https://github.com/tifa64" title="tifa64"><img src="https://github.com/tifa64.png?size=100" width="64" height="64" alt="tifa64"></a>
<a href="https://github.com/hossam-96" title="hossam-96"><img src="https://github.com/hossam-96.png?size=100" width="64" height="64" alt="hossam-96"></a>
<a href="https://github.com/aniketshukla1" title="aniketshukla1"><img src="https://github.com/aniketshukla1.png?size=100" width="64" height="64" alt="aniketshukla1"></a>
</p>

### Issue contributors

Thank you to everyone who opened issues, including bug reports, feature requests, questions, and documentation feedback.

<p>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aa-abdellatif98" title="a-abdellatif98"><img src="https://github.com/a-abdellatif98.png?size=100" width="64" height="64" alt="a-abdellatif98"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aa-elnemr" title="a-elnemr"><img src="https://github.com/a-elnemr.png?size=100" width="64" height="64" alt="a-elnemr"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AAbdelrahman-Shahda" title="Abdelrahman-Shahda"><img src="https://github.com/Abdelrahman-Shahda.png?size=100" width="64" height="64" alt="Abdelrahman-Shahda"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aaelnemr" title="aelnemr"><img src="https://github.com/aelnemr.png?size=100" width="64" height="64" alt="aelnemr"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aahmedashraffcih" title="ahmedashraffcih"><img src="https://github.com/ahmedashraffcih.png?size=100" width="64" height="64" alt="ahmedashraffcih"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aahmedgemi" title="ahmedgemi"><img src="https://github.com/ahmedgemi.png?size=100" width="64" height="64" alt="ahmedgemi"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AAhmedTheGeek" title="AhmedTheGeek"><img src="https://github.com/AhmedTheGeek.png?size=100" width="64" height="64" alt="AhmedTheGeek"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aahmedwael216" title="ahmedwael216"><img src="https://github.com/ahmedwael216.png?size=100" width="64" height="64" alt="ahmedwael216"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aalalm3i" title="alalm3i"><img src="https://github.com/alalm3i.png?size=100" width="64" height="64" alt="alalm3i"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aasami-me" title="asami-me"><img src="https://github.com/asami-me.png?size=100" width="64" height="64" alt="asami-me"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aatlas-apex" title="atlas-apex"><img src="https://github.com/atlas-apex.png?size=100" width="64" height="64" alt="atlas-apex"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aaureyia" title="aureyia"><img src="https://github.com/aureyia.png?size=100" width="64" height="64" alt="aureyia"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Abatout" title="batout"><img src="https://github.com/batout.png?size=100" width="64" height="64" alt="batout"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Abitwhispererrr" title="bitwhispererrr"><img src="https://github.com/bitwhispererrr.png?size=100" width="64" height="64" alt="bitwhispererrr"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aborzoj" title="borzoj"><img src="https://github.com/borzoj.png?size=100" width="64" height="64" alt="borzoj"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3ADr-kersho" title="Dr-kersho"><img src="https://github.com/Dr-kersho.png?size=100" width="64" height="64" alt="Dr-kersho"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Adrmas" title="drmas"><img src="https://github.com/drmas.png?size=100" width="64" height="64" alt="drmas"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aengnaruto" title="engnaruto"><img src="https://github.com/engnaruto.png?size=100" width="64" height="64" alt="engnaruto"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Ahamoda-dev" title="hamoda-dev"><img src="https://github.com/hamoda-dev.png?size=100" width="64" height="64" alt="hamoda-dev"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Ahazemahmedx0" title="hazemahmedx0"><img src="https://github.com/hazemahmedx0.png?size=100" width="64" height="64" alt="hazemahmedx0"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AHC12026" title="HC12026"><img src="https://github.com/HC12026.png?size=100" width="64" height="64" alt="HC12026"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aibrahim-gad" title="ibrahim-gad"><img src="https://github.com/ibrahim-gad.png?size=100" width="64" height="64" alt="ibrahim-gad"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AKarimEbrahemAbdelaziz" title="KarimEbrahemAbdelaziz"><img src="https://github.com/KarimEbrahemAbdelaziz.png?size=100" width="64" height="64" alt="KarimEbrahemAbdelaziz"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Akhaledmedra" title="khaledmedra"><img src="https://github.com/khaledmedra.png?size=100" width="64" height="64" alt="khaledmedra"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Amabdelaziz77" title="mabdelaziz77"><img src="https://github.com/mabdelaziz77.png?size=100" width="64" height="64" alt="mabdelaziz77"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AManito2z" title="Manito2z"><img src="https://github.com/Manito2z.png?size=100" width="64" height="64" alt="Manito2z"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AMedNewton" title="MedNewton"><img src="https://github.com/MedNewton.png?size=100" width="64" height="64" alt="MedNewton"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AMeDoTarek73" title="MeDoTarek73"><img src="https://github.com/MeDoTarek73.png?size=100" width="64" height="64" alt="MeDoTarek73"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AMina4lfy" title="Mina4lfy"><img src="https://github.com/Mina4lfy.png?size=100" width="64" height="64" alt="Mina4lfy"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AmohamedELamine" title="mohamedELamine"><img src="https://github.com/mohamedELamine.png?size=100" width="64" height="64" alt="mohamedELamine"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Amosta7il" title="mosta7il"><img src="https://github.com/mosta7il.png?size=100" width="64" height="64" alt="mosta7il"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Amostiwheelietravel" title="mostiwheelietravel"><img src="https://github.com/mostiwheelietravel.png?size=100" width="64" height="64" alt="mostiwheelietravel"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Amoussaws" title="moussaws"><img src="https://github.com/moussaws.png?size=100" width="64" height="64" alt="moussaws"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Amuhammadattia95" title="muhammadattia95"><img src="https://github.com/muhammadattia95.png?size=100" width="64" height="64" alt="muhammadattia95"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Anickyreinert" title="nickyreinert"><img src="https://github.com/nickyreinert.png?size=100" width="64" height="64" alt="nickyreinert"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AnLoops" title="nLoops"><img src="https://github.com/nLoops.png?size=100" width="64" height="64" alt="nLoops"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AOmar-Elhorbity" title="Omar-Elhorbity"><img src="https://github.com/Omar-Elhorbity.png?size=100" width="64" height="64" alt="Omar-Elhorbity"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AOmarEhab007" title="OmarEhab007"><img src="https://github.com/OmarEhab007.png?size=100" width="64" height="64" alt="OmarEhab007"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AOmarElaraby26" title="OmarElaraby26"><img src="https://github.com/OmarElaraby26.png?size=100" width="64" height="64" alt="OmarElaraby26"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Aosama-abu-baker" title="osama-abu-baker"><img src="https://github.com/osama-abu-baker.png?size=100" width="64" height="64" alt="osama-abu-baker"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3AOsamaAlSabry" title="OsamaAlSabry"><img src="https://github.com/OsamaAlSabry.png?size=100" width="64" height="64" alt="OsamaAlSabry"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Arafik-wahid-cubeish" title="rafik-wahid-cubeish"><img src="https://github.com/rafik-wahid-cubeish.png?size=100" width="64" height="64" alt="rafik-wahid-cubeish"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3ARef34t" title="Ref34t"><img src="https://github.com/Ref34t.png?size=100" width="64" height="64" alt="Ref34t"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Asudanese" title="sudanese"><img src="https://github.com/sudanese.png?size=100" width="64" height="64" alt="sudanese"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Ayehiagamalx" title="yehiagamalx"><img src="https://github.com/yehiagamalx.png?size=100" width="64" height="64" alt="yehiagamalx"></a>
<a href="https://github.com/me2resh/apexyard/issues?q=is%3Aissue%20author%3Azeyadsleem" title="zeyadsleem"><img src="https://github.com/zeyadsleem.png?size=100" width="64" height="64" alt="zeyadsleem"></a>
</p>

When updating these credits, include new issue authors as well as pull-request contributors.
Use public GitHub handles and links, and describe each contribution accurately.

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built with real-world experience shipping software with Claude Code.

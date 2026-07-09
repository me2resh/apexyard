<p align="center">
  <a href="https://yard.apexscript.com"><img src="https://yard.apexscript.com/brand/apexyard-avatar-512.png" alt="ApexYard" width="88"></a>
</p>

<h1 align="center">ApexYard</h1>

<p align="center">
  <strong>Take agent-built code the last mile — safely to production.</strong>
</p>

<p align="center">
  <a href="https://github.com/me2resh/apexyard/releases"><img src="https://img.shields.io/github/v/release/me2resh/apexyard?color=2F6DF6&label=release" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://claude.com/claude-code"><img src="https://img.shields.io/badge/built%20for-Claude%20Code-8A63D2" alt="Built for Claude Code"></a>
  <a href="https://yard.apexscript.com"><img src="https://img.shields.io/badge/site-yard.apexscript.com-2F6DF6" alt="Site"></a>
  <a href="https://github.com/me2resh/apexyard/stargazers"><img src="https://img.shields.io/github/stars/me2resh/apexyard?style=social" alt="Stars"></a>
</p>

## You built something real with AI. Then it fell apart.

The first 80% flew — a working prototype in a weekend, features landing faster than you could test them. Then the context slipped. The codebase turned into a pile nobody could review, decisions vanished into chat history, and the thing you were *so close* to shipping never actually made it to production.

**ApexYard is the machinery that takes agent-built code the last mile.** It wraps your AI coding agent in the discipline a real engineering team runs on: every change moves through a ticket, gets an independent review, and hits a merge gate that stays shut until a *named human* says "ship it." So the code your agent writes is actually safe to put in front of users.

Concretely, it's a multi-project **ops repo**: you fork it, register your projects, and govern them all as one organisation — shared memory across the portfolio, a strict SDLC, and **42 shell hooks** that enforce the rules mechanically instead of hoping everyone remembers them. Built for founders who ship alone, and for teams standing up AI-enabled squads.

Claude Code is the default driver, but the rules, hooks, and templates are plain markdown and shell. Swap the AI. Keep the forge. No SaaS. No lock-in.

**Proven shipping** TypeScript + AWS Lambda backends, Next.js web apps, Chrome extensions, and native **Swift** macOS desktop apps. The stack is process and guardrails — not a language or framework lock-in.

## Harness support

**ApexYard was built for Claude Code** — that's where everything is native. But the part that actually *enforces* your rules is plain bash, not tied to Claude Code, so other AI coding tools can run the **exact same rules** through a small adapter. We only claim what we've watched work: as of **2026-07-09**, three tools — **opencode, pi, and Codex** — are proven, meaning a real agent turn on each was stopped by the same unmodified rule. Each needs one small setting so the agent's command actually reaches the rule. Cursor is the honest exception.

| Tool | Enforces your rules? | Setup | Good to know |
|------|----------------------|-------|--------------|
| **Claude Code** | ✅ **Yes — natively.** Built in; the rules fire on every command. | Nothing to install — `/setup` and you're done. | On Windows, use Git Bash or WSL (the rules are bash). |
| **opencode** | ✅ **Yes — proven.** A real agent's `git add -A` was blocked by the same rule. | `bash bin/install-opencode-adapter.sh` | Run opencode with `--auto` so the agent's command reaches the rule. |
| **pi** | ✅ **Yes — proven.** Same, in a real pi session. | `bash bin/install-pi-adapter.sh` | Run pi with `-a` (auto-approve). pi is deliberately bare-bones — ApexYard is the governance it leaves to you. |
| **Codex** | ✅ **Yes — proven.** Same, in a real Codex session. | `bash bin/sync-codex-adapter.sh` | Codex has to trust the rules once — `/hooks`, a one-off flag, or a user-level install. |
| **Cursor** | 🟡 **Partly.** It blocks the command, but by *failing safe* when its rule-runner errors — not by running our rule. We don't count it as proven. | `bash bin/install-cursor-adapter.sh` | Works in the Cursor **IDE**, not the command-line version. Install is user-level (`~/.cursor/hooks.json`). |

*Under the hood:* your rules stay one set of portable bash scripts, and every tool reads the **same** ones — never a separate copy that can drift out of sync. Full per-tool setup, limits, and how to add a new tool → **[`docs/harnesses/`](docs/harnesses/README.md)**.

> **Not on Claude Code?** opencode, pi, and Codex run the same gates today (Cursor partially). Install your tool's adapter — the one command in the table above — and the identical rules enforce. One honest caveat before the Quick Start below: the `/setup`, `/handover`, and other `/…` commands are Claude Code **skills**, a convenience layer. The enforcement that actually matters — the gates — is what your tool's adapter delivers; on another tool you set up the same plain-text config files by hand (the steps note how).

## Codex Adapter

ApexYard can generate a Codex-facing adapter from the canonical `.claude/` runtime:

```bash
bin/sync-codex-adapter.sh
```

The generator emits Codex-facing skills, agents, and hook wiring into `.agents/` and `.codex/` without embedding local clone paths. Gate decisions still run through the unmodified `.claude/hooks/*.sh` scripts. See [`docs/codex-adapter.md`](docs/codex-adapter.md) for the tracking policy, AgDR, and drift-check workflow.

## What's inside

ApexYard is a set of plain-text primitives Claude Code reads automatically — no runtime, no service:

- **20 roles** across 6 departments (engineering, product, design, security, data, architecture) that activate on triggers
- **42 shell hooks** that mechanically enforce the SDLC — ticket-first edits, a two-marker merge gate, migration gates, secrets scanning, and more
- **64 slash-command skills** — from `/setup` and `/handover` to `/decide`, `/code-review`, `/migration`, and `/launch-check`
- **25 sub-agents** — Rex (code review), Hakim (security), Tariq (design review), plus the department personas
- **15 rule files**, workflow docs, and document templates (PRD, tech design, ADR, AgDR, C4 diagrams)

**Full directory tree and the complete role / hook / skill / agent breakdown → [`docs/whats-inside.md`](docs/whats-inside.md).**

> **Marketing site:** the site that was previously bundled here has moved to its own repo ([me2resh/apexyard-site](https://github.com/me2resh/apexyard-site)) and is deployed independently at [yard.apexscript.com](https://yard.apexscript.com).
>
> **For AI coding agents:** the repo root carries `AGENTS.md` — universal entry doc for Cursor / Claude Code / Aider / Cline / **pi**. For harnesses that don't auto-load `CLAUDE.md` (pi chief among them), `AGENTS.md`'s "Operator governance bridge" section carries the same advisory SDLC governance `CLAUDE.md` gives Claude Code — see [`docs/harnesses/pi.md`](docs/harnesses/pi.md) for what's bridged today vs. not yet.

## Quick Start — fork and go

ApexYard governs a **portfolio of repos** as one organisation. You fork apexyard, clone the fork, treat it as your "ops repo", and register every project you want under management. No `.apexyard/` symlinks, no nested installs — the fork IS the ops repo.

> **On opencode, pi, or Codex?** Steps 1–3 are the same (they're just `git` / `gh`). Then install your tool's adapter — one command, see the [Harness support](#harness-support) table above — and the gates enforce on your tool. The `/setup` and `/handover` steps below are Claude Code **skills**; on another tool you set up the same plain-text config files by hand, which each step shows. The rules that get enforced are identical either way.

### 1. Star + Fork on GitHub

Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard), **Star** it, then **Fork** it into your org. You can keep the fork named `apexyard` or rename to something that fits your naming convention (`your-org/ops`, `your-org/apex`, etc.).

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

Later, run **`/update`** to pull the latest apexyard improvements into your fork — it previews the upstream diff, merges on a sync branch, and walks you through any per-version migrations (don't hand-merge `main`).

### 4. Configure the framework — run `/setup`

Run **`/setup`** in Claude Code. In three exchanges (describe your stack → review the proposed defaults → accept or tweak) it captures your company, team, tech stack, and quality bar and writes your config.

```text
/setup
```

Your real config lives in `onboarding.yaml`, which is **gitignored** — it stays local and is never published. `/setup` copies it from the tracked `onboarding.example.yaml` placeholder and fills it in, so nothing private is committed. (A commit-time guard blocks a filled-in `onboarding.yaml` if you ever try to add it.)

*Not on Claude Code?* There's no `/setup` skill to run — do the same thing by hand: `cp onboarding.example.yaml onboarding.yaml` and fill in your company, stack, and quality bar. The gates don't depend on the skill; they read the file.

### 5. Register your projects — run `/handover`

Projects join the portfolio through a skill, not hand-edited YAML. For each repo you want under management:

```text
/handover <repo-url-or-local-path>
```

**`/handover`** clones the repo, scores its "harnessability" across five dimensions, seeds its per-project docs, and **registers it in `apexyard.projects.yaml`** (creating the registry on first use). `/setup` also offered to register your first project back in step 4.

The registry it maintains looks like this — you rarely touch it by hand:

```yaml
version: 1
projects:
  - name: example-app
    repo: your-org/example-app
    docs: projects/example-app
    status: active
```

Register even a single repo — the portfolio skills (`/projects`, `/inbox`, `/status`) work off the registry. (Not on Claude Code, or prefer to bootstrap it by hand? `cp apexyard.projects.yaml.example apexyard.projects.yaml` and add your repos — same registry, no skill required.)

### 6. Start working

```
/projects          # list every managed project + status
/inbox             # PRs, issues, comments needing your attention
/status            # git + CI snapshot per project
/decide            # make a technical decision (creates an AgDR)
```

The hooks fire on every `git` / `gh` command, the portfolio skills aggregate across the registry, and the Code Reviewer agent can be invoked with `/code-review <pr>`.

Full setup guide with directory layout, daily workflow, and FAQ: [`docs/multi-project.md`](docs/multi-project.md).

Keeping a fork current — upgrade in place, when to re-fork instead, and how to preserve your portfolio data either way: [`docs/upgrading.md`](docs/upgrading.md).

## Why ApexYard?

**The problem**: Claude Code is powerful, but without structure it produces inconsistent results. Every team reinvents the same processes -- role definitions, review checklists, document templates, workflow gates.

**The solution**: ApexYard provides that structure as a reusable, open-source stack. One config file to customize, 20 role definitions to use, battle-tested workflows to follow, and 42 shell hooks that enforce the rules mechanically.

### What makes it different

| Feature | Without ApexYard | With ApexYard |
|---------|-------------------|----------------|
| Code reviews | Ad-hoc prompts | Rex agent on every PR, SHA-bound approval marker |
| Technical decisions | Lost in chat history | Documented as Agent Decision Records |
| Quality gates | Hope and pray | 42 shell hooks block bad commits, forged markers, unreviewed merges |
| Merge approval | Informal "LGTM" | Two-marker gate — Rex (code) + CEO (per-PR explicit) |
| Database migrations | Drop-column-on-Friday | Dedicated gate: labelled ticket + migration AgDR (rollback, downtime, consumers) required before schema edits |
| Architecture docs | Nobody draws them | C4 L1 + L2 Mermaid templates + `/c4` skill generates stubs from a codebase |
| Portfolio visibility | Tab through 5 GitHubs | `/inbox`, `/status`, `/tasks` aggregate across a single registry file |
| Upstream sync | Forget for 6 months | Session-start drift banner + `/update` skill |
| Role consistency | Re-explain every session | Persistent role definitions, activation-triggered |
| Onboarding | Days of context-setting | `/setup` three-exchange config |

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
7. **Merge requires two markers** — Rex's approval + explicit per-PR CEO approval via `/approve-merge <pr>`. Plan-level "go" doesn't count.

For larger changes (new skills, rule changes, workflow redesigns), open a discussion or draft PRD first.

## Contributors

Thanks to everyone who has helped forge ApexYard:

<table>
  <tr>
    <td align="center"><a href="https://github.com/me2resh"><img src="https://github.com/me2resh.png?size=100" width="64" alt="me2resh"><br><sub><b>me2resh</b></sub></a></td>
    <td align="center"><a href="https://github.com/AbdElrahmaN31"><img src="https://github.com/AbdElrahmaN31.png?size=100" width="64" alt="AbdElrahmaN31"><br><sub>AbdElrahmaN31</sub></a></td>
    <td align="center"><a href="https://github.com/HishamM1"><img src="https://github.com/HishamM1.png?size=100" width="64" alt="HishamM1"><br><sub>HishamM1</sub></a></td>
    <td align="center"><a href="https://github.com/tifa64"><img src="https://github.com/tifa64.png?size=100" width="64" alt="tifa64"><br><sub>tifa64</sub></a></td>
    <td align="center"><a href="https://github.com/hossam-96"><img src="https://github.com/hossam-96.png?size=100" width="64" alt="hossam-96"><br><sub>hossam-96</sub></a></td>
  </tr>
</table>

<sub>External contributors' PRs are squash-merged, so GitHub's commit-author graph under-counts them — this list credits the humans directly. New contributor? Open a PR and you'll be added.</sub>

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built with real-world experience shipping software with Claude Code.

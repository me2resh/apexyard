# Getting Started with ApexYard

Short version of the setup flow. For the full walkthrough (directory layout, daily workflow, upgrade path, FAQ) see [`multi-project.md`](multi-project.md).

---

## Prerequisites

- A GitHub account and an org you can fork into
- [Claude Code](https://claude.com/claude-code) installed
- [GitHub CLI (`gh`)](https://cli.github.com) installed (optional but recommended)
- [`jq`](https://jqlang.org/download/) installed — required. Framework hooks use jq to read `.claude/project-config.json` overrides; without it your overrides silently no-op. `brew install jq` / `apt-get install jq` / `dnf install jq` depending on platform. `/setup` refuses to run without it, and a SessionStart banner surfaces the gap if jq disappears later. See [AgDR-0038](agdr/AgDR-0038-jq-as-hard-dependency.md) for the rationale.
- Basic familiarity with Claude Code's `CLAUDE.md` system

---

## Step 1: Fork apexyard on GitHub

Your ops repo **is** a fork of apexyard. One repo, no nested installs.

Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard), **Star** it, then **Fork** it into your org. Rename the fork if you want (`your-org/ops`, `your-org/apex`, or keep it as `apexyard` — GitHub handles the rename cleanly).

Then clone your fork locally:

```bash
gh repo fork me2resh/apexyard --clone
cd apexyard
```

Or with plain git:

```bash
git clone https://github.com/your-org/apexyard.git
cd apexyard
```

Add the upstream remote so you can pull future updates:

```bash
git remote add upstream https://github.com/me2resh/apexyard.git
```

Later, `git fetch upstream && git merge upstream/main` pulls the latest apexyard improvements into your fork.

---

## Step 2: Configure for Your Team

Edit `onboarding.yaml` with your company details:

```yaml
company:
  name: "Acme Corp"
  mission: "Making widgets simple"

team:
  - name: "Alice"
    role: "tech-lead"
    department: "engineering"
  - name: "Bob"
    role: "backend-engineer"
    department: "engineering"
  - name: "Charlie"
    role: "product-manager"
    department: "product"

tech_stack:
  language: "TypeScript"
  framework: "Next.js"
  database: "PostgreSQL"
  hosting: "Vercel"
```

---

## Step 3: Create the portfolio registry

Copy the example registry and list every repo you want under management:

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

Even if you have just one repo, register it — the skills work the same whether you have 1 or 20.

The `CLAUDE.md` at the root of your fork is the stack entry point. Claude Code reads it automatically when you start a session inside the fork — no additional wiring needed.

---

## Step 4: Start Using It

### Ask Claude Code to act as a role

```
Review this PR as the QA Engineer
```

```
As the Security Auditor, check this code for vulnerabilities
```

### Use the workflow

```
I'm starting work on ticket #42. Walk me through the SDLC process.
```

### Generate documents from templates

```
Create a PRD for the user authentication feature
```

```
Write a technical design for the payment processing system
```

### Record decisions

```
I need to decide between PostgreSQL and DynamoDB for this service.
Create an AgDR.
```

---

## Optional: LSP-aware code navigation

Claude Code v2.0.74+ ships a built-in **LSP (Language Server Protocol) tool** that answers semantic queries — *"where is this defined?"*, *"where is this used?"*, *"what does this symbol resolve to?"* — by talking to a language server (`tsserver`, `pyright`, `gopls`, `rust-analyzer`, etc.) instead of grepping the file tree. It is **off by default** and **opt-in per session**.

### Why turn it on?

The LSP spike (PR #184, ticket #178) measured the input-token cost of three representative queries on a real TypeScript backend (~9,750 LOC). Shallow semantic queries — single-symbol lookups, find-references — came out **~3-15× cheaper** with LSP than with grep + Read. Multi-hop traces (chains of definitions across modules) saw a smaller ~1.4× win, because the irreducible cost is still reading prose to summarise behaviour.

Concretely: a Code Reviewer agent run on a typical PR that does a handful of "where is this defined" lookups can come in at a quarter to a tenth of its grep-driven token bill, with the saved budget freed up for the actual review reasoning.

### Easy path — `/setup` automates it

Run `/setup` (first run) or `/setup --enable-lsp` (retrofit on an already-configured fork) and the skill walks you through three things in one offer:

1. **Detects your language** from the `tech_stack` you described in `/setup` (or from the existing `onboarding.yaml` if you're retrofitting).
2. **Installs the language server** (`typescript-language-server`, `pyright`, `gopls`, or `rust-analyzer`) using the right package manager for the detected language. Refuses gracefully if the prerequisite runtime (`node`, `python`, `go`, `rustup`) is missing — it never auto-installs runtimes.
3. **Sets `ENABLE_LSP_TOOL=1` in your shell rc** (`~/.zshrc`, `~/.bashrc`, or `~/.profile` depending on `$SHELL`) — idempotently, so re-running is a no-op.
4. **Prints the verified plugin-install copy-paste block** for your language. Three commands to run *inside Claude Code* (not the shell): `/plugin marketplace add anthropics/claude-plugins-official`, `/plugin install <plugin-name>@claude-plugins-official`, and `/reload-plugins`. The skill substitutes the right `<plugin-name>` for your detected language (e.g. `typescript-lsp`, `pyright-lsp`, `gopls-lsp`, `rust-analyzer-lsp`). The marketplace add is always emitted because the docs' auto-load claim for `claude-plugins-official` doesn't always fire on fresh installs.

The skill defaults to **on** for typical machines (≥ 4 cores AND ≥ 8 GB RAM) and **off** for constrained machines, with the operator free to override either way. Re-running `/setup --enable-lsp` is idempotent: if the env var and server binary are already in place, it reports "already enabled" and exits.

Windows is out of scope for v1 of the LSP automation — `/setup` prints a manual-install pointer back to this section and continues without LSP.

### Opt-in path — manual fallback (two pieces)

If you'd rather skip the skill and wire it up yourself — or you're on Windows and `/setup` declined to automate it — LSP is enabled by **two** things:

1. The environment variable `ENABLE_LSP_TOOL=1` (singular `_TOOL`, not plural).
2. A per-language plugin from the official Anthropic marketplace.

Both are required. Setting only the env var without an installed plugin gives Claude Code nothing to talk to; installing only the plugin without the env var keeps the tool dormant.

Add the env var to your shell rc so it loads on every shell start:

```bash
echo 'export ENABLE_LSP_TOOL=1' >> ~/.zshrc   # or ~/.bashrc
```

Then install the plugin for your language. Inside Claude Code (not your shell), run:

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install <plugin-name>@claude-plugins-official
/reload-plugins
```

Substituting `<plugin-name>` for one of:

| Language | Plugin |
|---|---|
| TypeScript / JavaScript | `typescript-lsp` |
| Python | `pyright-lsp` |
| Go | `gopls-lsp` |
| Rust | `rust-analyzer-lsp` |

Other languages (C/C++, C#, Java, Kotlin, Lua, PHP, Swift) are also covered — see the [discover-plugins reference](https://code.claude.com/docs/en/discover-plugins#code-intelligence) for the full table. The marketplace add is idempotent (no-op if already registered — the docs claim `claude-plugins-official` auto-loads on Claude Code startup, but in practice the auto-add can be missing on a fresh install, so always emit it).

> **Gotcha — env var not visible to the current process.** `ENABLE_LSP_TOOL=1` written to your shell rc is **not** picked up by the Claude Code process you're currently in. `/reload-plugins` reloads plugin state but does **not** re-read shell env. After adding the env var (and after installing the plugin), fully **quit** and **relaunch** Claude Code. Verify with `echo $ENABLE_LSP_TOOL` in a fresh shell — it should print `1`.

### Per-language install notes

The framework actively encourages LSP for these four. Pick the languages your project uses; multi-language repos can install several plugins side-by-side and the LSP tool will dispatch per-file based on extension.

#### TypeScript / JavaScript — `tsserver`

`tsserver` ships bundled with the TypeScript compiler (`typescript` on npm), which most TS projects already have as a devDependency. No extra binary install if your repo has `node_modules`.

```bash
# Verify your project ships tsserver
npx tsserver --version 2>/dev/null || npm ls typescript

# Install the Claude Code plugin — run inside Claude Code, not the shell:
#   /plugin install typescript-lsp@claude-plugins-official
```

#### Python — `pyright`

```bash
# Install pyright globally
npm install -g pyright

# Or per-project via uv / pip
uv add --dev pyright
# pip install pyright

# Then install the Python plugin — run inside Claude Code, not the shell:
#   /plugin install pyright-lsp@claude-plugins-official
```

`pyright` understands `pyproject.toml` and `pyrightconfig.json` for path resolution; if your repo uses a virtualenv the plugin needs to know where it lives — set `python.pythonPath` in `pyrightconfig.json`.

#### Go — `gopls`

```bash
# Install gopls (the official Go language server)
go install golang.org/x/tools/gopls@latest

# Verify it's on $PATH
which gopls

# Then install the Go plugin — run inside Claude Code, not the shell:
#   /plugin install gopls-lsp@claude-plugins-official
```

`gopls` requires Go 1.21+ and a `go.mod` at the repo root. Cold start on a large monorepo can take 30–90 seconds while the module graph builds.

#### Rust — `rust-analyzer`

`rust-analyzer` ships bundled with [rustup](https://rustup.rs/) — most Rust toolchains already have it.

```bash
# Add the component if it's missing
rustup component add rust-analyzer

# Verify
rust-analyzer --version

# Then install the Rust plugin — run inside Claude Code, not the shell:
#   /plugin install rust-analyzer-lsp@claude-plugins-official
```

Cargo workspaces with many crates have a slow first index — see the caveat below.

### Caveats — what LSP does not solve

- **Cold-start latency on large repos.** The first query against a fresh server pays the indexing cost: a few seconds for a small library, 30-90s for a Go monorepo or a large Rust workspace, sometimes longer for a TypeScript project with thousands of files. Subsequent queries in the same session are fast. Plan for the first call to be slow; budget for it in agent runs.
- **Cross-project portfolio queries still need grep.** LSP indexes one project at a time. Skills that walk the whole portfolio (`/inbox`, `/tasks`, `/stakeholder-update`, anything that aggregates across `apexyard.projects.yaml`) read across many repos and stay on grep + Read regardless of LSP state.
- **No new failure mode.** Skills that benefit from LSP (`/code-review`, `/threat-model`, `/security-review`) fall back to grep + Read transparently when LSP is absent. There is no "broken without LSP" path — only a faster one with it.
- **Plugin marketplace links may move.** The plugin ecosystem is young. If a marketplace search turns up multiple options for one language, prefer the one maintained by the language's own community (e.g. official `tsserver` over a third-party wrapper).

## Optional: Local agent routing

Agents can optionally route through a locally-running Ollama instance via a LiteLLM proxy — useful when you want to keep prompts off any cloud API for specific sub-tasks (ticket triage, data-analyst sketches, exploratory rephrasing). See [`local-model-setup.md`](local-model-setup.md) for the install + configuration walkthrough.

**Opt-in only.** Absence of an `endpoint:` field in your `agent-routing.yaml` keeps every agent on its framework default. Nothing in the default `/setup` output enables this.

Before opting in, read the [local-model-routing spike memo](spikes/local-model-routing.md) — it measured cold-start latency and tool-call reliability against real workloads and recommends bounded use, not whole-portfolio routing.

---

## Customization

### Adding a Custom Role

Create a new file in `roles/your-department/your-role.md`:

```markdown
# Role: [Role Name]

## Identity
You are a [Role Name]. You [primary responsibility].

## Responsibilities
- [Responsibility 1]
- [Responsibility 2]

## Capabilities

### CAN Do
- [Capability 1]

### CANNOT Do
- [Limitation 1]

## Interfaces
| Direction | Role | Interaction |
|-----------|------|-------------|
| Reports to | [Role] | [How] |

## Escalate When
- [Condition 1]
```

### Modifying a Workflow

Edit files in `workflows/` to match your team's process. For example, if you don't have a separate QA phase, remove it from `workflows/sdlc.md`.

### Adding a Template

Drop new markdown templates in `templates/` and reference them in `CLAUDE.md`.

---

## What to Expect

After setup, Claude Code will:

1. **Understand your team structure** -- It knows who does what
2. **Follow your SDLC** -- It enforces workflow gates
3. **Use your standards** -- Code reviews follow the defined checklist
4. **Generate structured docs** -- PRDs, tech designs, ADRs from templates
5. **Track decisions** -- Agent Decision Records for technical choices

---

## Troubleshooting

### Claude Code doesn't seem to know about the stack

Make sure you're running Claude Code from inside your fork of apexyard (the ops repo). Claude Code reads `CLAUDE.md` automatically from the working directory's root — if you're one level deep (e.g. inside `workspace/<project>/`) it picks up the project's own `CLAUDE.md` instead.

### Roles aren't being applied correctly

Check that the role file exists in the expected path under `roles/`.

### Workflows feel too heavy for my team

Customize! Edit `onboarding.yaml` to disable stages:

```yaml
workflows:
  require_prd: false
  require_technical_design: false
  require_qa_signoff: false
```

---

## Next Steps

- Browse the [roles](../roles/) to see all available role definitions
- Read the [workflows](../workflows/) to understand the development process
- Check the [templates](../templates/) for document formats
- Star the [GitHub repo](https://github.com/me2resh/apexyard) for updates

# Getting Started with ApexYard

Short version of the setup flow. For the full walkthrough (directory layout, daily workflow, upgrade path, FAQ) see [`multi-project.md`](multi-project.md).

---

## Prerequisites

- A GitHub account and an org you can fork into
- [Claude Code](https://claude.com/claude-code) installed
- [GitHub CLI (`gh`)](https://cli.github.com) installed (optional but recommended)
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

### Opt-in path — two pieces

LSP is enabled by **two** things in the same session:

1. The environment variable `ENABLE_LSP_TOOL=1` (singular `_TOOL`, not plural).
2. A per-language plugin that ships the LSP server binary and the `.lsp.json` wiring.

Both are required. Setting only the env var without an installed plugin gives Claude Code nothing to talk to; installing only the plugin without the env var keeps the tool dormant.

Set the env var for your session:

```bash
export ENABLE_LSP_TOOL=1
claude
```

Or add it to your shell profile if you want it on by default. Plugins install through Claude Code's plugin marketplace — start at the [Claude Code plugins documentation](https://docs.claude.com/en/docs/claude-code/plugins) and search for the language you need.

### Per-language install notes

The framework actively encourages LSP for these four. Pick the languages your project uses; multi-language repos can install several plugins side-by-side and the LSP tool will dispatch per-file based on extension.

#### TypeScript / JavaScript — `tsserver`

`tsserver` ships bundled with the TypeScript compiler (`typescript` on npm), which most TS projects already have as a devDependency. No extra binary install if your repo has `node_modules`.

```bash
# Verify your project ships tsserver
npx tsserver --version 2>/dev/null || npm ls typescript

# Install the Claude Code plugin from the marketplace
# (search "typescript" / "tsserver" in the marketplace UI)
```

#### Python — `pyright`

```bash
# Install pyright globally
npm install -g pyright

# Or per-project via uv / pip
uv add --dev pyright
# pip install pyright

# Then install the Python plugin from the marketplace
# (search "python" / "pyright")
```

`pyright` understands `pyproject.toml` and `pyrightconfig.json` for path resolution; if your repo uses a virtualenv the plugin needs to know where it lives — set `python.pythonPath` in `pyrightconfig.json`.

#### Go — `gopls`

```bash
# Install gopls (the official Go language server)
go install golang.org/x/tools/gopls@latest

# Verify it's on $PATH
which gopls

# Then install the Go plugin from the marketplace
# (search "go" / "gopls")
```

`gopls` requires Go 1.21+ and a `go.mod` at the repo root. Cold start on a large monorepo can take 30–90 seconds while the module graph builds.

#### Rust — `rust-analyzer`

`rust-analyzer` ships bundled with [rustup](https://rustup.rs/) — most Rust toolchains already have it.

```bash
# Add the component if it's missing
rustup component add rust-analyzer

# Verify
rust-analyzer --version

# Then install the Rust plugin from the marketplace
# (search "rust" / "rust-analyzer")
```

Cargo workspaces with many crates have a slow first index — see the caveat below.

### Caveats — what LSP does not solve

- **Cold-start latency on large repos.** The first query against a fresh server pays the indexing cost: a few seconds for a small library, 30-90s for a Go monorepo or a large Rust workspace, sometimes longer for a TypeScript project with thousands of files. Subsequent queries in the same session are fast. Plan for the first call to be slow; budget for it in agent runs.
- **Cross-project portfolio queries still need grep.** LSP indexes one project at a time. Skills that walk the whole portfolio (`/inbox`, `/tasks`, `/stakeholder-update`, anything that aggregates across `apexyard.projects.yaml`) read across many repos and stay on grep + Read regardless of LSP state.
- **No new failure mode.** Skills that benefit from LSP (`/code-review`, `/threat-model`, `/security-review`) fall back to grep + Read transparently when LSP is absent. There is no "broken without LSP" path — only a faster one with it.
- **Plugin marketplace links may move.** The plugin ecosystem is young. If a marketplace search turns up multiple options for one language, prefer the one maintained by the language's own community (e.g. official `tsserver` over a third-party wrapper).

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

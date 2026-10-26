# Getting Started with ApexYard

This page gives the short setup flow. See [`multi-project.md`](multi-project.md)
for the directory layout, daily workflow, upgrade path, and FAQ.

---

## Prerequisites

- A GitHub account and an organisation where you can create a fork
- An installation of [Claude Code](https://claude.com/claude-code)
- An installation of [GitHub CLI (`gh`)](https://cli.github.com). `apexyard init` needs this tool. The fork method can use the web UI.
- An installation of [`jq`](https://jqlang.org/download/). The framework needs jq. Framework hooks use jq to read `.claude/project-config.json` overrides. Without jq, the hooks silently ignore your overrides. Use `brew install jq` / `apt-get install jq` / `dnf install jq` for your platform. `/setup` refuses to run without jq. A SessionStart banner shows a warning if jq disappears later. See [AgDR-0038](agdr/AgDR-0038-jq-as-hard-dependency.md) for the reason.
- **Windows**: Use [Git for Windows](https://gitforwindows.org) or WSL. The
  `.claude/hooks/*.sh` files use Bash. Native `cmd.exe` and PowerShell cannot
  run them. The project fixed the `C:`-drive path issue that [#691](https://github.com/me2resh/apexyard/issues/691) reports.
- Basic familiarity with Claude Code's `CLAUDE.md` system

After cloning, run `bash bin/apexyard doctor` before `/setup`, or use
`apexyard doctor` if the CLI is on PATH. `/preflight` runs the same checks
inside Claude Code. The report suggests fixes and makes no changes.
Exit codes are 0 (pass), 1 (warning), and 2 (failure).

On Windows, install the optional GitHub CLI with `winget install GitHub.cli`.
Install jq 1.6 or later with `winget install jqlang.jq`. You need jq. Run the
check in Git Bash or WSL.

---

## Step 1: Create your ops repo

### Default: `apexyard init`

Install the CLI. Then create your ops repo with one command:

```bash
curl -fsSL https://apexyard.ai/install | sh   # CLI only; no sudo; checks the release checksum
apexyard init --org your-org --name ops --private
```

You can also install the CLI with `brew install me2resh/tap/apexyard`.

Or run `npx create-apexyard --org your-org --name ops --private`. It installs
the CLI when the CLI is absent, then runs `apexyard init` with these options.
Do not run `apexyard init` again after it, because the target directory is no
longer empty.

The project has not yet published the install URL, the Homebrew tap, or the npm package.
Until the project publishes them, use the fork method below. `apexyard init` needs `git`,
`jq` and `gh`.

`apexyard init` creates a new repo from the framework, so it can be private.
It clones the repo, adds the framework as the remote `upstream`, and writes
`.claude/framework-version`. Use `--public` for a public repo and `--agent NAME`
to record your agent tool. Add `--dry-run` to see the plan only.

To update later, run `apexyard update`. It shows which files change and who
owns them, then starts `/update`. Use `apexyard update --check` to preview only.

When you set an install endpoint, `apexyard init` sends one anonymous install event.
The event contains a random install id, the CLI version, your operating system, and the agent tool.
Today the CLI has no endpoint. The CLI prints the event and sends
nothing. Set `APEXYARD_TELEMETRY=0` to stop these events.

Go to Step 2.

### Alternative: fork apexyard on GitHub

Your ops repo can also be a fork of ApexYard. GitHub does not allow a private
fork of a public repo. It is one repository with no nested install.

Visit [`github.com/me2resh/apexyard`](https://github.com/me2resh/apexyard).
Give it a star. Then fork it into your organisation. Keep `apexyard`, or rename the
fork to a name such as `your-org/ops`.

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

Add the upstream remote so you can pull updates later:

```bash
git remote add upstream https://github.com/me2resh/apexyard.git
```

Later, fetch and merge from `upstream/main` to update your fork:

```bash
git fetch upstream
git merge upstream/main
```

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

Register your repo even if you have only one. The skills work the same whether you have 1 or 20.

The `CLAUDE.md` at the root of your fork is the stack entry point.
Claude Code reads it automatically when you start a session inside the fork. You need no additional configuration.

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

### Turn on branch protection

Turn on required review and required status checks on your protected branches. The hooks help enforce rules but do not provide a security boundary. See the [Threat model](../SECURITY.md#threat-model).

---

## Terminal push hook (`core.hooksPath`)

The framework includes a `.githooks/pre-push` hook for `git push`. After installation, git runs it the same way for terminal pushes and Claude Code pushes. It runs two check sets in order. First, `bin/run-pre-push-checks.sh` runs the framework's hardcoded checks: markdownlint, shellcheck, and the subpack extraction smoke test. Then `bin/run-configured-pre-push-checks.sh` runs this repo's configured `.pre_push.commands`.

Plain rule (AgDR-0173, AgDR-0115): ApexYard runs `.pre_push.commands` only inside an ApexYard fork that has this hook installed. ApexYard never runs local pre-push checks in a managed-project clone. ApexYard never sets `core.hooksPath` in a managed clone (AgDR-0115). That clone's own CI is its fallback check.

Before AgDR-0173, the Claude Code hook (`pre-push-gate.sh`) ran a repository's `.pre_push.commands` itself, sometimes against the wrong repository (me2resh/apexyard#1366). It selected a target repository from the Bash command's text. No design of this method could make it sound. It could also pick the wrong repository. A heredoc, a quoted string, or a commit message could all look like a push without being one.

After AgDR-0173, `pre-push-gate.sh` runs no repository's commands. On every matching push, it only reminds the session to install the git hook above. It gives this reminder only when the session's working-directory repo is an ApexYard fork. In a managed-project clone, it prints at most a one-line note that ApexYard runs no checks there. It never suggests installing `core.hooksPath` in a repo that is not an ApexYard fork.

### `/setup` installs the hook automatically

As of me2resh/apexyard#1086, `/setup` runs `bin/install-git-hooks.sh` for you. After `/setup`, a fresh ops-fork clone has `core.hooksPath` pointing at `.githooks`.
The `check-git-hooks-installed.sh` SessionStart advisory gives warnings without blocking work, as `check-upstream-drift.sh` does. It warns if a clone's `core.hooksPath` has any of these conditions:

- It has no value.
- It points at a deleted directory.
- It still points into a different clone's `.git/hooks`.

If you skipped `/setup`, or want to run it by hand:

```bash
bash bin/install-git-hooks.sh
```

You can safely run the installer again. It repairs the stale pointers above automatically. It refuses to overwrite a `core.hooksPath` you deliberately set to something else unless you pass `--force`. See `bash bin/install-git-hooks.sh --help`.

Git stores `core.hooksPath` in each clone's configuration and never commits it. The installer must run once for each clone. Thus, `/setup` calls it for the ops fork instead of leaving a manual step for you to remember.

`/handover` deliberately does not call the installer for a newly cloned managed-project workspace. The installer only checks whether a `.githooks/` directory exists. It does not check the directory's source. If you run the installer against an arbitrary newly cloned third-party repo, the next ordinary git operation can execute that repo's committed hook scripts. This needs no push. The PR #1087 security review confirmed this HIGH finding.

See the "1.5-clone" step in `.claude/skills/handover/SKILL.md` for the full reason. The open follow-up me2resh/apexyard#1088 addresses protection for a managed-project clone's own terminal pushes without this risk.

`--global` also works (`git config --global core.hooksPath .githooks`) if you want to cover every clone on a machine at once. It affects every git repo on that machine, not only apexyard. If other repos include their own hooks under `.git/hooks/`, the global setting overrides those hooks. The installer's default configuration for each clone is safer.

### Missing tools degrade gracefully

Each check first looks for its tool. If `shellcheck` or `npx` is missing, the check prints installation instructions and skips the check (exit 0). The check never blocks a contributor who lacks a tool. The check still runs in CI.

### Emergency bypass

Use the bypass only for a real one-off emergency. Put `<!-- pre-push: skip -->` on its own line in the HEAD commit message (subject or body). A sentence that only mentions the marker does not bypass checks. The hook prints the bypass to stderr. You can see it in terminal output and find it with grep in history. The skip deliberately covers only one push per commit, not all future pushes.

```bash
git commit --amend -m "$(git log -1 --format=%B)
<!-- pre-push: skip -->"
```

### Checks in the set

| Check | What it catches | Tool required |
|-------|----------------|---------------|
| `markdownlint` | Malformed markdown, for example broken tables and duplicate headings, with markdownlint-cli2 | `npx` (Node.js) |
| `shellcheck` | Shell-script bugs, quoting issues, portability problems in `.claude/hooks/*.sh` | `shellcheck` |
| ~~`site-counts`~~ | Retired. The marketing site moved to me2resh/apexyard-site (#663). | None |
| `subpacks` | Marketplace sub-pack extraction smoke test. Confirms that extraction leaked no framework-private files. | none (bash) |

The check set deliberately excludes link-check (lychee). It runs slowly and needs network access, so it would delay pre-push checks too much.

### Writing-profile check (advisory)

`bin/run-pre-push-checks.sh` also runs `bin/check-writing-profile.sh` after the
checks above (me2resh/apexyard#1418 item 6). It reports semicolons and
sentences over 25 words in the Markdown lines a push adds, using the
controlled technical writing profile in `.claude/rules/writing-standard.md`.

This check is advisory only. It always exits 0. It never blocks a push, even
when it finds faults or crashes. Run it by hand before opening a PR:

```bash
bash bin/check-writing-profile.sh
```

---

## Managing model cost: why the main agent dominates spend

The per-agent model matrix ([AgDR-0050](agdr/AgDR-0050-agent-runtime-overhaul.md)) applies only to sub-agents. The main agent starts these sub-agents for reviews, QA, and analysis. The main agent adopts implementation, PM, and design work in the same thread. This design uses your primary tier, usually Opus. Thus, the `sonnet` implementation default never takes effect. This explains why the main agent uses most tokens.

Three methods control cost. They are in order of benefit for effort, best first:

1. Use `opusplan`: Opus plans and Sonnet executes. This gives the largest benefit without framework changes.
2. Use the thin-orchestrator pattern. Keep the Opus loop as a planner and coordinator. Assign implementation to `sonnet` build agents that the main agent starts with `/fan-out` or `Workflow`.
3. Add entries to `agent-routing.yaml` to set or route per-agent tiers.

See [`docs/orchestrator-cost-model.md`](orchestrator-cost-model.md) for the full explanation and the optional thin-orchestrator mode.

**Idle CI waits and the prompt cache.** The orchestrator uses a Monitor to wait for green CI before it starts a reviewer. The main conversation stays idle during this time. A subscription inside its usage limits keeps the main prompt cache for 1 hour. An API key, Bedrock, Vertex, or Foundry keeps it for 5 minutes. A CI wait longer than 5 minutes then rebuilds the whole main context. If you run outside subscription limits, set `promptCacheTtl` to `"1h"` in your Claude Code settings where your provider supports it. The `CLAUDE_CODE_PROMPT_CACHE_TTL` environment variable does the same. First, check that your provider accepts a 1-hour cache. See [`.claude/rules/pr-workflow.md`](../.claude/rules/pr-workflow.md) for the rule text.

**Bounding the main context.** On a 1M-context Opus model, Claude Code compacts at about 967K tokens by default. A long orchestrator session then carries a large context on every turn. The `autoCompactWindow` setting lowers the compaction point. The spike [GH-1637](spike-memos/GH-1637-compaction-threshold.md) shows that the setting limits the context per turn. The maximum context stayed 30K to 43K tokens below the window. The setting is optional. Use it only when long sessions carry more context than you want and you accept more compactions. If you use it, set it in your user settings, not in a shared project file:

```json
{
  "autoCompactWindow": 500000
}
```

- **Recommended value:** `500000`. This value is an extrapolation from windows of 100K to 400K. Criterion ac2-2 of the token-efficiency plan must confirm it with `bin/token-cost.py`.
- **Allowed values:** a whole number from `100000` to `1000000`. Claude Code limits it to the model window.
- **Other ways to set it:** use the `--autocompact` flag for one launch with Claude Code 2.1.221 or later. Use `/autocompact` for one model with 2.1.288 or later. Use `CLAUDE_CODE_AUTO_COMPACT_WINDOW` in scripts. The variable accepts a plain integer only.
- **Quality:** a lower window means more compactions. Each compaction can remove details from a long task. The spike used a weak quality test. Check long tasks after you set a low window.
- **Cost:** the spike found no cost saving. In two runs each, a window of 100K cost about 9 percent more than the default. Each compaction rebuilds the prompt cache. Do not go below 300K without a measurement.

---

## Optional: LSP-aware code navigation

Claude Code v2.0.74+ includes an LSP (Language Server Protocol) tool that answers semantic queries. Examples include these queries:

- Where does the code define this?
- Where does the code use this?
- What does this symbol resolve to?

The tool communicates with a language server instead of searching the file tree with grep. Servers include `tsserver`, `pyright`, `gopls`, and `rust-analyzer`. The tool stays off by default. You must enable it for each session.

### Why turn it on?

The LSP spike (PR #184, ticket #178) measured input-token cost for three representative queries on a real TypeScript backend (~9,750 LOC). Shallow semantic queries, such as single-symbol lookups and reference searches, cost ~3-15× less with LSP than with grep + Read. Multi-hop traces follow chains of definitions across modules. These traces cost only ~1.4× less, because the agent must still read prose to summarize behavior.

A Code Reviewer agent run on a typical PR can use fewer tokens. It can use a quarter to a tenth of the tokens of a review that uses grep. This applies when the review includes a few definition lookups. The agent can use the remaining token budget for review reasoning.

### Easy path: `/setup` automates it

Run `/setup` for the first run, or `/setup --enable-lsp` to add LSP to a fork that you already configured. The skill guides you through four things in one offer:

1. The skill detects your language from the `tech_stack` you described in `/setup`. The skill uses existing `onboarding.yaml` if you retrofit.
2. The skill installs the language server (`typescript-language-server`, `pyright`, `gopls`, or `rust-analyzer`). The skill uses the right package manager for the detected language.

   The skill refuses installation if the prerequisite runtime (`node`, `python`, `go`, or `rustup`) is missing. The skill never installs runtimes by itself.

3. The skill sets `ENABLE_LSP_TOOL=1` in your shell rc file (`~/.zshrc`, `~/.bashrc`, or `~/.profile`, depending on `$SHELL`).

   The skill makes this change only if it is not there yet.

4. The skill prints the verified plugin-install block for your language.

   Run its three commands inside Claude Code, not the shell: `/plugin marketplace add anthropics/claude-plugins-official`, `/plugin install <plugin-name>@claude-plugins-official`, and `/reload-plugins`. The skill replaces `<plugin-name>` with the name for your language, for example `typescript-lsp`, `pyright-lsp`, `gopls-lsp`, or `rust-analyzer-lsp`. The skill always prints the marketplace add command. The documentation states that `claude-plugins-official` loads automatically, but fresh installations do not always do this.

The skill defaults to on for typical machines with ≥ 4 cores AND ≥ 8 GB RAM. It defaults to off for machines with fewer resources. The operator can change either default. Repeated runs of `/setup --enable-lsp` do not repeat configuration changes. If the environment variable and server binary already exist, the skill reports "already enabled" and exits.

The first version of the LSP automation does not support Windows. On Windows, `/setup` shows a manual-install reference to this section and continues without LSP.

### Opt-in path: manual fallback (two pieces)

You can configure LSP manually instead of using the skill. Use this method on Windows if `/setup` declines to automate configuration. LSP needs two things:

- The environment variable `ENABLE_LSP_TOOL=1` (singular `_TOOL`, not plural).
- A per-language plugin from the official Anthropic marketplace.

LSP needs both. With only the environment variable, Claude Code has no plugin to communicate with. With only the plugin, the tool stays inactive.

Add the environment variable to your shell configuration file so each shell start loads it:

```bash
echo 'export ENABLE_LSP_TOOL=1' >> ~/.zshrc   # or ~/.bashrc
```

Then install the plugin for your language. Run these commands inside Claude Code, not your shell:

```
/plugin marketplace add anthropics/claude-plugins-official
/plugin install <plugin-name>@claude-plugins-official
/reload-plugins
```

Replace `<plugin-name>` with one of these names:

| Language | Plugin |
|---|---|
| TypeScript / JavaScript | `typescript-lsp` |
| Python | `pyright-lsp` |
| Go | `gopls-lsp` |
| Rust | `rust-analyzer-lsp` |

Plugins also support C/C++, C#, Java, Kotlin, Lua, PHP, and Swift. See the [discover-plugins reference](https://code.claude.com/docs/en/discover-plugins#code-intelligence) for the full table. The marketplace add command makes no change if the marketplace already exists. The documentation states that `claude-plugins-official` loads automatically when Claude Code starts. Fresh installations can omit this automatic addition, so always include the command.

> **Warning: the current process does not see the environment variable.** The current Claude Code process does not read `ENABLE_LSP_TOOL=1` from your changed shell configuration file. `/reload-plugins` reloads plugin state but does not read shell environment variables again. After you add the environment variable and install the plugin, quit Claude Code fully. Then start Claude Code again. Check with `echo $ENABLE_LSP_TOOL` in a fresh shell. The command should print `1`.

### Per-language install notes

The framework encourages LSP for these four languages. Select the languages that your project uses. A repository with multiple languages can use several plugins together. The LSP tool selects the plugin for each file from its extension.

#### TypeScript / JavaScript: `tsserver`

The TypeScript compiler (`typescript` on npm) includes `tsserver`. Most TypeScript projects already have the compiler as a devDependency. If your repository has `node_modules`, you do not need to install another binary.

```bash
# Verify your project ships tsserver
npx tsserver --version 2>/dev/null || npm ls typescript

# Install the Claude Code plugin — run inside Claude Code, not the shell:
#   /plugin install typescript-lsp@claude-plugins-official
```

#### Python: `pyright`

```bash
# Install pyright globally
npm install -g pyright

# Or per-project via uv / pip
uv add --dev pyright
# pip install pyright

# Then install the Python plugin — run inside Claude Code, not the shell:
#   /plugin install pyright-lsp@claude-plugins-official
```

`pyright` uses `pyproject.toml` and `pyrightconfig.json` for path resolution. If your repository uses a virtualenv, the plugin needs the location of the virtualenv. Set `python.pythonPath` in `pyrightconfig.json`.

#### Go: `gopls`

```bash
# Install gopls (the official Go language server)
go install golang.org/x/tools/gopls@latest

# Verify it's on $PATH
which gopls

# Then install the Go plugin — run inside Claude Code, not the shell:
#   /plugin install gopls-lsp@claude-plugins-official
```

`gopls` needs Go 1.21+ and a `go.mod` at the repository root. A cold start on a large monorepo can take 30 to 90 seconds while the module graph builds.

#### Rust: `rust-analyzer`

[rustup](https://rustup.rs/) includes `rust-analyzer`. Most Rust toolchains already have it.

```bash
# Add the component if it's missing
rustup component add rust-analyzer

# Verify
rust-analyzer --version

# Then install the Rust plugin — run inside Claude Code, not the shell:
#   /plugin install rust-analyzer-lsp@claude-plugins-official
```

Cargo workspaces with many crates take a long time to index initially. See the caveat below.

### Caveats: what LSP does not solve

- **Cold-start latency on large repositories.** The first query to a fresh server needs time for indexing. A small library needs a few seconds. A Go monorepo or large Rust workspace needs 30-90s. A TypeScript project with thousands of files sometimes needs more time. Later queries in the same session are fast. Plan time for the first call in agent runs.
- **Cross-project portfolio queries still need grep.** LSP indexes one project at a time. Portfolio-wide skills include `/inbox`, `/tasks`, `/stakeholder-update`, and anything that collects information across `apexyard.projects.yaml`. These skills read many repositories and use grep + Read regardless of LSP state.
- **No new failure mode.** Skills that benefit from LSP include `/code-review`, `/threat-model`, and `/security-review`. They automatically use grep + Read when LSP is absent. These skills work without LSP and run faster with it.
- **Plugin marketplace links may move.** The plugin ecosystem is new. If a marketplace search shows multiple options for one language, select the plugin that the language's own community maintains. For example, select official `tsserver` instead of a third-party wrapper.

## Optional: Fallow static analysis (JS/TS)

For JavaScript / TypeScript projects, the Code Reviewer agent (Rex) can run [Fallow](https://docs.fallow.tools) static analysis during every code review. The analysis finds dead code, unused exports and dependencies, duplication, circular dependencies, and high complexity in changed code. It also previews fixes with a dry run. See `.claude/agents/code-reviewer.md` § 9 and [AgDR-0069](agdr/AgDR-0069-fallow-in-code-review.md).

You must enable this optional analysis. Rex runs it only when the diff touches `**/*.{js,jsx,mjs,cjs,ts,tsx}` AND the `fallow` CLI exists on `PATH`. If the CLI is absent, Rex silently skips the step. Reviews work without Fallow and give more information with it. Findings are advisory (`nit:` / `suggestion:`). They never change a verdict on their own. The review only previews fixes (`fallow fix --dry-run`). It never changes your tree.

To enable it on a JS/TS project:

1. Install the `fallow` CLI with `cargo install fallow-cli`, or run it when needed with `npx fallow`.
2. Optionally, set `quality.fallow_review: false` in `onboarding.yaml` to disable the review analysis while keeping the CLI.

   An absent value or `true` enables analysis when the CLI exists.

Non-JS/TS stacks need no action. The language check prevents analysis of non-JS/TS diffs regardless of the flag. An absent `fallow` CLI also causes Rex to skip analysis. An unset `quality.fallow_review` equals `true`. This setting matters only for JS/TS projects that have the CLI and need to disable analysis.

## Optional: Local agent routing

Agents can optionally route through a local Ollama instance with a LiteLLM proxy. This keeps prompts away from cloud APIs for specific tasks, such as ticket triage, data-analyst sketches, and exploratory rephrasing. See [`local-model-setup.md`](local-model-setup.md) for installation and configuration instructions.

You must enable local routing explicitly. If your `agent-routing.yaml` has no `endpoint:` field, every agent keeps its framework default. The default `/setup` output does not enable local routing.

Before you enable local routing, read the [local-model-routing spike memo](spikes/local-model-routing.md). It measured cold-start latency and tool-call reliability with real workloads. It recommends limited use, rather than whole-portfolio routing.

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

Edit files in `workflows/` to match your team's process. For example, if you do not have a separate QA phase, remove it from `workflows/sdlc.md`.

### Adding a Template

Add new markdown templates to `templates/`. Reference them in `CLAUDE.md`.

---

## What to Expect

After setup, Claude Code will:

- Understand your team structure and who does each task.
- Follow your SDLC and enforce workflow gates.
- Use your standards, with code reviews that follow the defined checklist.
- Generate structured PRDs, technical designs, and ADRs from templates.
- Track technical choices in Agent Decision Records.

---

## Troubleshooting

### Claude Code does not seem to know about the stack

Run Claude Code from inside your fork of apexyard, the ops repository. Claude Code automatically reads `CLAUDE.md` from the working directory's root. If you work one level deeper, for example inside `workspace/<project>/`, Claude Code reads that project's own `CLAUDE.md` instead.

### Claude Code does not apply roles correctly

Check that the role file exists in the expected path under `roles/`.

### Workflows feel too heavy for my team

Edit `onboarding.yaml` to disable stages:

```yaml
workflows:
  require_prd: false
  require_technical_design: false
  require_qa_signoff: false
```

---

## Next Steps

- Browse the [roles](../roles/) to see all available role definitions.
- Read the [workflows](../workflows/) to understand the development process.
- Check the [templates](../templates/) for document formats.
- Star the [GitHub repo](https://github.com/me2resh/apexyard) for updates.

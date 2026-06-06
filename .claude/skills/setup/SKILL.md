---
name: setup
description: First-run framework bootstrap — 3 exchanges (describe stack → defaults → accept/customize) and the fork is configured.
disable-model-invocation: false
argument-hint: "[--reset] [--enable-lsp]"
effort: medium
---

# /setup — ApexYard First-Run Bootstrap

Configures `onboarding.yaml` for a new ApexYard fork in three exchanges instead of eight sequential questions. The "describe, propose, confirm" pattern gets most users from fork to working in under 2 minutes.

## Path resolution

Read the registry path via `portfolio_registry`, the per-project docs dir via `portfolio_projects_dir`, and the ideas backlog via `portfolio_ideas_backlog` — all from `.claude/hooks/_lib-portfolio-paths.sh`. Source the helper at the top of any bash block that touches those paths:

```bash
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
registry=$(portfolio_registry)
```

Defaults match today's single-fork layout (`./apexyard.projects.yaml`, `./projects`, `./projects/ideas-backlog.md`). Adopters in split-portfolio mode override the `portfolio.{registry, projects_dir, ideas_backlog}` keys in `.claude/project-config.json`. Don't hardcode literal `apexyard.projects.yaml` or `projects/` paths in bash blocks — the helper resolves whichever mode the adopter is in. See `docs/multi-project.md`.

## When this runs

The `onboarding-check.sh` SessionStart hook prompts the user to run `/setup` when the fork isn't configured — either there's no real `onboarding.yaml` yet (a fresh clone ships only the tracked `onboarding.example.yaml` placeholder), or `onboarding.yaml` still has the `company.name: "Your Company Name"` placeholder. After `/setup` fills in real values, the hook goes silent on this machine. Note (#517): in single-fork mode `onboarding.yaml` is GITIGNORED — real config stays local — so each fresh clone runs `/setup` once (it copies the example and fills it in). In split-portfolio v2 mode the real config is committed in the private sibling repo, so it carries across clones.

Re-running `/setup` on an already-configured fork shows the current config and asks what to update. Use `--reset` to clear everything and start from scratch.

## Process

> **Tip for the agent driving setup**: `docs/multi-project.md` is the canonical reference for portfolio modes, v1→v2 migration, custom-templates path-mirroring, the FAQ, and trade-offs. As of #372 it is **not** auto-imported into the session context (the 70k-char file was loading ~18k tokens into every session, even for adopters who never re-run setup). The steps below are self-contained for the mechanical setup. If a first-timer asks a question mid-setup that this SKILL doesn't answer directly, `Read docs/multi-project.md` on demand rather than guessing.

### Step −1: Pre-flight — refuse if `jq` is missing (REQUIRED)

`/setup` (and every framework hook that reads `.claude/project-config.json` overrides) depends on `jq`. Without it, override reads silently fall back to defaults — the adopter's `.ui_paths`, `.tracker.*`, `.migration_paths`, etc. have zero effect and there's no error to debug. Refuse to proceed until jq is on PATH so the operator never sees the silently-degraded state.

Run this **before any other tool call** in the skill:

```bash
if ! command -v jq >/dev/null 2>&1; then
  cat <<'MSG'
✗ ApexYard requires `jq` for reading project-config overrides, but it's not installed.

Install instructions:
  macOS:   brew install jq
  Debian:  apt-get install jq
  Fedora:  dnf install jq
  Other:   https://jqlang.org/download/

Once installed, re-run /setup.
MSG
  exit 1
fi
```

The sibling `check-jq-installed.sh` SessionStart hook surfaces the same gap as a one-line banner outside `/setup` so a fork that's already configured (and never re-runs `/setup`) still sees the warning. See AgDR-0038 for the design rationale.

### Step 0: Mark this session as bootstrap (REQUIRED)

`/setup` runs BEFORE any portfolio is configured, so no project tickets can exist yet. The `require-active-ticket.sh` PreToolUse hook would otherwise block every Edit / Write / Bash-write the skill needs to make. To stay coherent with the ticket-first rule without forcing adopters to file a placeholder ticket against nothing, the skill writes a one-line marker at `.claude/session/active-bootstrap` containing the skill name. The hook reads the marker and exempts skills listed in `ticket.bootstrap_skills` (in `.claude/project-config.defaults.json` — `setup` is on the default list).

Run this **before any tool calls that edit files**:

```bash
mkdir -p .claude/session && echo "setup" > .claude/session/active-bootstrap
```

The marker is cleared in Step 8 below (and on the next SessionStart by `clear-bootstrap-marker.sh`, in case this skill is interrupted).

See AgDR-0011 + me2resh/apexyard#150 for the design rationale.

### Step 1: Check current state

Read `onboarding.yaml`. Four modes:

- **First run** (`onboarding.yaml` absent, or placeholder values detected): proceed to Step 2. The real file is gitignored (#517), so an absent `onboarding.yaml` with a present `onboarding.example.yaml` is the normal fresh-fork state — Step 6 copies the example before editing.
- **Already configured** (real values): show a summary of the current config and ask "What would you like to update?" — then jump to the specific section. Don't re-ask everything.
- **`--reset` flag**: restore `onboarding.yaml` to the template defaults (`cp onboarding.example.yaml onboarding.yaml`) and proceed as first run.
- **`--enable-lsp` flag** (retrofit mode): skip Steps 2 / 2a / 2b / 3-7 entirely and jump straight to Step 2c (LSP enablement). Use this when an existing adopter has a fully-configured fork and only wants to turn on LSP without re-running the whole bootstrap. The flag honours the same idempotence rules as a first-run pass through Step 2c — if LSP is already enabled, the step reports "already enabled" and exits cleanly. Step 0 (bootstrap marker) and Step 8 (clear marker) still run so the ticket gate stays coherent.

Detection: `[ ! -f onboarding.yaml ]` (fresh fork — only the example is present) OR `grep -q '"Your Company Name"' onboarding.yaml` (file present but still a template) → treat as first run.

### Step 2: One question — describe your world

Ask a single open-ended question:

```
Tell me about your company and tech stack in a few sentences.
For example: "We're a 3-person startup building a property management
SaaS. TypeScript + React frontend, AWS SAM backend with DynamoDB.
GitHub Issues for tracking, 1-week sprints."
```

**Do NOT ask sequential questions.** The whole point of this skill is to collapse the discovery into one natural-language exchange. The user describes their world; you parse it.

### Step 2a: Privacy gate — ask if any projects are private

Before parsing the description into config, ask one privacy question — this determines whether the adopter needs single-fork or split-portfolio mode (see `docs/multi-project.md`):

```
Quick one before I propose your config: are any of the projects you'll
manage on this fork private (i.e. not visible to the public)?

Why I'm asking: GitHub Free disallows changing a fork's visibility, so
under the standard fork-and-commit setup you might accidentally publish
your private project names on a public GitHub repo (a stray `git push`
after registering them — I won't push without your approval, but the
risk is on the adopter once the data is committed locally). If any
project is private, I'll walk you through the split-portfolio mode (a
separate private repo for the registry, public fork stays slim).

[y / n / "I'm on GitHub Pro/Team/Enterprise" — last option supports
private forks of public repos and avoids the issue.]
```

Branch on the answer:

- **n** (all projects public) → continue with **single-fork mode** (default; the rest of this skill applies as-is).
- **paid plan** (Pro / Team / Enterprise) → continue with **single-fork mode**, but mention that the registry will be on the (private-fork-eligible) fork and is fine.
- **y** (any private projects on GitHub Free) → switch to **split-portfolio mode** (Step 2b below).

Detection of an existing setup. Either form counts as "already in split-portfolio mode" — skip Step 2b:

- `.claude/project-config.json` has a `portfolio:` block pointing at a sibling repo (config-block mode, recommended; introduced #145), OR
- `apexyard.projects.yaml` is a symlink (`test -L apexyard.projects.yaml`; legacy mode, framework-version < #145).

### Step 2b: Walk through split-portfolio mode (only if Step 2a triggered)

The full setup lives in `docs/multi-project.md` § "Split-portfolio mode — public framework + private portfolio". This skill walks through it interactively. The recommended path uses the **`portfolio:` config block** (introduced in #145) rather than symlinks — both work, but the config block is the first-class option:

1. **Confirm the layout**: "Two repos in your account: `your-org/apexyard` (public, this fork) + `your-org/<private-name>` (new private repo for the portfolio). Both clones sit side-by-side on disk. OK?"
2. **Pick the private repo name**: default suggestion **`your-org/<fork>-portfolio`** (e.g. `your-org/apexyard-portfolio` if you kept the fork name; `your-org/cos-portfolio` if you renamed the fork to `cos`). Compute the `<fork>` part from the public-fork repo name (`gh repo view --json name -q .name`) so the suggestion is correct even when the fork was renamed. Operator confirms or overrides — any name works, the framework only cares about the local path.
3. **Create the private repo**: `gh repo create your-org/<name> --private --description "..."`. Confirm before running.
4. **Clone the private repo as a sibling**: `cd .. && gh repo clone your-org/<name>` (no second arg — the clone defaults to a directory named after the repo, so `your-org/apexyard-portfolio` clones into `apexyard-portfolio/`).
5. **Initialise the portfolio (v2 layout)**: in the private repo, create:
   - `apexyard.projects.yaml` with `version: 1`, `projects: []`, `defaults: {status: active, ticket_prefix: GH}`
   - empty `projects/` dir (with a `.gitkeep` so the dir survives the initial commit)
   - empty `workspace/` dir (with a `.gitkeep`) — managed-project clones land here
   - **`onboarding.yaml`** seeded from the framework template — split-portfolio v2 (#242) moves company/team/stack config to the private repo too, so the public fork stays slim
   - empty **`custom-skills/`** dir + a one-paragraph `custom-skills/README.md` explaining the convention. Company-specific proprietary skills (`/file-internal-bug`, `/check-policy`, etc.) live as `custom-skills/<name>/SKILL.md` here; the public fork's `link-custom-skills.sh` SessionStart hook symlinks each into `.claude/skills/<name>/` so Claude Code discovers them. Custom skill names override framework skills of the same name (warning printed at SessionStart). See `docs/multi-project.md` § "Private custom skills + handbooks" for the full convention. (Added in #243.)
   - empty **`custom-handbooks/`** dir + a one-paragraph `custom-handbooks/README.md` explaining the convention. Company-confidential coding standards live as `custom-handbooks/{architecture,general,language/<lang>}/*.md` here, mirroring the public `handbooks/` path-convention. Rex consumes both layers during code review (advisory by default, blocking with `ENFORCEMENT: blocking` at the top of the file). See `handbooks/README.md` for the format. (Added in #243.)
   - **`agent-routing.yaml`** seeded from `<fork>/agent-routing.yaml.example` (the framework's worked-examples file). This is the adopter-routing source-of-truth for split-portfolio mode — every adopter override (per-agent model, endpoint, env, timeout) lives here. The seeded file starts as the framework example so adopters see a working shape; the empty `agents: {}` block at the top means zero overrides until edited. The SessionStart sync hook (`apply-agent-routing.sh`, #357) reads it on every session start. See `docs/multi-project.md` § "Centralised agent routing — `agent-routing.yaml`" for the schema. (Added in #351 PR 3.)
   - `.gitignore` with `workspace/*/` so the inner clones don't get double-tracked in the private repo either
   - initial commit + push
6. **Configure path resolution in the fork** (recommended — v2 config-block mode):
   - Append `.gitignore` lines for `apexyard.projects.yaml`, `projects`, `onboarding.yaml`, AND `workspace` so none of them get accidentally staged in the public fork even on a stray `git add -A`. (The first two cover registry + per-project docs; the last two are the v2 additions.)
   - Untrack any tracked `projects/README.md`, `onboarding.yaml`, or `workspace/README.md` from the upstream framework: `git rm --cached -r projects onboarding.yaml workspace 2>/dev/null || true`.
   - Write `.claude/project-config.json` with the v2 `portfolio:` block pointing at the sibling repo. Substitute the actual sibling-dir name the operator chose for `apexyard-portfolio` below:

     ```json
     {
       "portfolio": {
         "registry": "../apexyard-portfolio/apexyard.projects.yaml",
         "projects_dir": "../apexyard-portfolio/projects",
         "ideas_backlog": "../apexyard-portfolio/projects/ideas-backlog.md",
         "onboarding": "../apexyard-portfolio/onboarding.yaml",
         "workspace_dir": "../apexyard-portfolio/workspace",
         "custom_skills_dir": "../apexyard-portfolio/custom-skills",
         "custom_handbooks_dir": "../apexyard-portfolio/custom-handbooks",
         "agent_routing": "../apexyard-portfolio/agent-routing.yaml"
       }
     }
     ```

     The two `custom_*_dir` keys are optional — defaults match `./custom-skills` and `./custom-handbooks` resolved against the ops-fork root. The `agent_routing` key is similarly optional — its default resolves to `./agent-routing.yaml` against the ops-fork root, so single-fork adopters who keep the file at the fork root don't need to set it explicitly. Setting all three explicitly here is the v2 split-portfolio shape and matches what step 5 just created in the private repo.

   - **Write the `.apexyard-fork` marker** at the public-fork root. This is the v2 ops-fork anchor — `_lib-ops-root.sh` and every hook that walks up to find the ops fork looks for this marker first (with the legacy `onboarding.yaml + apexyard.projects.yaml` pair as fallback). **Spec: presence-only — readers MUST ignore content; only file presence matters.** Writers MAY include a single explanatory line so `head .apexyard-fork` is informative for operators encountering it the first time. See [AgDR-0021](../../../docs/agdr/AgDR-0021-split-portfolio-v2-path-resolution.md) § B for the rationale.

     ```bash
     # Either form is valid — both are presence-only as far as readers are concerned:
     echo "# This file marks the directory as an ApexYard ops fork (split-portfolio v2)." > .apexyard-fork
     # OR (strictly empty, also valid):
     # touch .apexyard-fork
     ```

   - Stage `.gitignore`, `.claude/project-config.json`, and `.apexyard-fork` for commit. All three are per-fork, not per-machine.
   - **Legacy fallback (framework-version < #145)**: if the adopter's framework predates the `portfolio:` config block, fall back to creating symlinks pointing at `../<sibling-dir>/apexyard.projects.yaml` and `../<sibling-dir>/projects`. The helper resolves either way. v2 (`onboarding` / `workspace_dir` / `.apexyard-fork`) requires framework ≥ #242 — older forks should run `/update` first to pick up the v2 plumbing before going through this branch.
7. **Verify**: source `.claude/hooks/_lib-portfolio-paths.sh` and call `portfolio_validate`. Skill MUST refuse to declare success if validate fails — surface the specific failure and ask the operator to fix it before re-running.

   ```bash
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-read-config.sh"
   source "$(git rev-parse --show-toplevel)/.claude/hooks/_lib-portfolio-paths.sh"
   if ! portfolio_validate; then
     echo "Setup not complete — fix the issue above and re-run /setup"
     exit 1
   fi
   ```

Then proceed to Step 2c with the user's earlier description, configuring `onboarding.yaml` as normal. The rest of the skill is unchanged — the only difference between modes is where the registry physically lives.

**Do NOT auto-migrate** an adopter who's already in single-fork mode with private project names already pushed. Direct them to the migration guide in `docs/multi-project.md` § "Migrating from single-fork to split-portfolio" — that flow involves a force-push history rewrite, redacting GitHub Issue / PR bodies, and a backup-branch dance, and is destructive enough to warrant a deliberate, eyes-open run rather than a `/setup` side-effect.

### Step 2c: LSP enablement (recommended)

Background. Claude Code v2.0.74+ ships a built-in LSP (Language Server Protocol) tool that answers semantic queries — "where is this defined?", "find references", "what does this symbol resolve to?" — by talking to a language server (`tsserver`, `pyright`, `gopls`, `rust-analyzer`) instead of grepping the file tree. The LSP spike (PR #184) measured **~3-15× cheaper** input-token cost on shallow semantic queries used by `/code-review`, `/threat-model`, `/security-review`, and `/handover` deep-dives. The framework's encouraged default is **on**.

The manual opt-in path (still documented in `docs/getting-started.md` § "Optional: LSP-aware code navigation") is three steps spread across env-var + binary install + plugin install. This step bakes those three into one offer so the typical adopter gets LSP working out of the box.

#### Step 2c.1 — Machine-spec heuristic for the default

LSP servers are non-trivial: a cold `gopls` or `rust-analyzer` index on a large repo can spike RAM by 1-4 GB. On constrained machines, LSP is more friction than benefit. Compute a default answer **before** prompting:

```bash
# Cores
CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)

# RAM (GB) — try /proc/meminfo on Linux, sysctl on macOS, fall back to 0
RAM_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null \
       || sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1024/1024/1024)}' \
       || echo 0)

if [ "$CORES" -lt 4 ] || [ "$RAM_GB" -lt 8 ]; then
  LSP_DEFAULT="n"
  LSP_DEFAULT_REASON="constrained hardware (cores=$CORES, ram_gb=$RAM_GB)"
else
  LSP_DEFAULT="y"
  LSP_DEFAULT_REASON="recommended on this machine (cores=$CORES, ram_gb=$RAM_GB)"
fi
```

Use `LSP_DEFAULT` as the highlighted choice in the prompt below — the operator can still pick the other option, but the default reflects what the machine can comfortably run.

#### Step 2c.2 — Idempotence check (skip if already enabled)

Before prompting, detect whether LSP is already fully enabled on this machine. If both conditions hold, **skip the prompt** and report "already enabled":

1. **Env var already set in shell rc.** Pick the right rc file from `$SHELL`:

   ```bash
   case "$SHELL" in
     */zsh)  RC_FILE="$HOME/.zshrc" ;;
     */bash) RC_FILE="$HOME/.bashrc" ;;
     *)      RC_FILE="$HOME/.profile" ;;
   esac

   ENV_VAR_SET=0
   if [ -f "$RC_FILE" ] && grep -q 'ENABLE_LSP_TOOL=1' "$RC_FILE"; then
     ENV_VAR_SET=1
   fi
   ```

2. **Language-server binary on PATH.** Map the detected language to its binary (see Step 2c.3 below) and `command -v` for it:

   ```bash
   # Example for TypeScript — substitute the binary that matches the detected language
   SERVER_INSTALLED=0
   if command -v typescript-language-server >/dev/null 2>&1; then
     SERVER_INSTALLED=1
   fi
   ```

If `ENV_VAR_SET=1` and `SERVER_INSTALLED=1`, print:

```
LSP already enabled on this machine (env var set in <rc-file>, <server-binary>
on PATH). Skipping install. Next Claude Code session will use LSP.
```

…and continue to Step 3 without prompting. This is the path that retrofit-flag (`/setup --enable-lsp`) re-runs hit on the second invocation — the skill stays silent rather than re-installing.

#### Step 2c.3 — Detect the language from the user's description

Map signals from the `tech_stack` description the operator gave in Step 2 (or read from the existing `onboarding.yaml` in retrofit mode). The mapping table:

| Signals in description / `tech_stack.language` / `tech_stack.framework` | Detected language | Server binary | Install command (preferred) |
|---|---|---|---|
| "TypeScript", "JavaScript", "React", "Next", "Node", "Vue", "Svelte", "Express", "Fastify", "NestJS" | `typescript` | `typescript-language-server` | `npm install -g typescript typescript-language-server` |
| "Python", "Django", "FastAPI", "Flask" | `python` | `pyright` | `pipx install pyright` (fallback: `pip install --user pyright`) |
| "Go", "Golang" | `go` | `gopls` | `go install golang.org/x/tools/gopls@latest` |
| "Rust", "Cargo", "rustup" | `rust` | `rust-analyzer` | `rustup component add rust-analyzer` |

If the description mentions **multiple** matching languages (e.g. "TypeScript frontend + Python backend"), pick the language used by the primary application code — i.e. whichever language the operator is most likely to run `/code-review` against. When ambiguous, ask one explicit clarifying question:

```
Your stack mentions TypeScript and Python — which one should LSP target
first? (You can install the other server later by re-running /setup --enable-lsp.)
```

If no language matches the table, default to `typescript` (the LSP spike's baseline) and tell the operator they can install another server manually later — don't silently install anything they didn't ask for.

#### Step 2c.4 — Ask the operator (with the computed default)

Present the offer as a single block, with the heuristic default highlighted:

```
LSP enablement (recommended)

LSP-aware code navigation makes /code-review, /threat-model,
/security-review, and /handover deep-dives 3-15× cheaper in token cost
on semantic queries (measured on a real TypeScript backend; see
docs/getting-started.md § "Optional: LSP-aware code navigation" for the
spike summary).

Enable LSP now? This will:
  - Install the language server for {detected-language} ({install-command})
  - Set ENABLE_LSP_TOOL=1 in your shell rc ({rc-file})
  - Install the Claude Code LSP plugin for {detected-language} (or print
    the manual install command if the marketplace command shape isn't
    supported on your harness yet)

Default for this machine: {LSP_DEFAULT}  ({LSP_DEFAULT_REASON})

[y / n / "y, but ask before each install step"]
```

Branch on the answer:

- **y** (or operator pressed enter with `LSP_DEFAULT=y`) → proceed to Step 2c.5 and run all three installs without further prompting (unless one fails — see Step 2c.6).
- **n** (or operator pressed enter with `LSP_DEFAULT=n`) → skip Steps 2c.5–2c.7 entirely. Print: *"LSP skipped. You can enable it later via `/setup --enable-lsp` or by following the manual steps in `docs/getting-started.md` § "Optional: LSP-aware code navigation"."* Continue to Step 3.
- **"ask before each"** (any phrasing — "step through", "one at a time", etc.) → run Step 2c.5 with `INTERACTIVE=1` so each sub-step asks for confirmation before mutating state.

#### Step 2c.5 — Run the three install steps

Each sub-step is **independent and idempotent** — a failure in one doesn't roll back the others, and re-running on a machine where one is already done is a no-op. Print a one-line result for each.

##### (a) Refuse on Windows for v1

If the harness is Windows (detect via `$OSTYPE` containing "msys", "cygwin", or "win32", or `uname -s` starting with "MINGW" / "CYGWIN" / "Windows"), do NOT attempt any installs. Print:

```
LSP automation on Windows is not supported in this release. Follow the
manual steps in docs/getting-started.md § "Optional: LSP-aware code
navigation" — the same three pieces (env var, language-server install,
plugin install), just executed by hand. Continuing without LSP.
```

…and skip the rest of Step 2c. Continue to Step 3.

##### (b) Install the language server

For each detected language, the install command and its prerequisite check:

| Language | Prerequisite check | Install command |
|---|---|---|
| `typescript` | `command -v npm` | `npm install -g typescript typescript-language-server` |
| `python` | `command -v pipx \|\| command -v pip3` | `pipx install pyright` (or `pip3 install --user pyright`) |
| `go` | `command -v go` | `go install golang.org/x/tools/gopls@latest` |
| `rust` | `command -v rustup` | `rustup component add rust-analyzer` |

If the prerequisite is missing, refuse gracefully — do NOT attempt to auto-install Node, Python, Go, or Rust runtimes (that's out of scope, and silently installing language runtimes is the wrong shape). Example refusal for TypeScript:

```bash
if ! command -v npm >/dev/null 2>&1; then
  echo "✗ npm not found on PATH. Install Node.js first (https://nodejs.org/), then re-run /setup --enable-lsp."
  LSP_SERVER_INSTALLED=0
else
  npm install -g typescript typescript-language-server
  if command -v typescript-language-server >/dev/null 2>&1; then
    echo "✓ typescript-language-server installed."
    LSP_SERVER_INSTALLED=1
  else
    echo "✗ install succeeded but binary not on PATH. Check your npm global bin (npm config get prefix)."
    LSP_SERVER_INSTALLED=0
  fi
fi
```

The other three languages follow the same shape — prerequisite check → install → verify-on-PATH → report. **Do not** continue to (c) or (d) if (b) fails on its own prerequisite; the env var and plugin without a server is dead weight. Tell the operator what's missing and move on.

##### (c) Set the env var idempotently in the shell rc

```bash
case "$SHELL" in
  */zsh)  RC_FILE="$HOME/.zshrc" ;;
  */bash) RC_FILE="$HOME/.bashrc" ;;
  *)      RC_FILE="$HOME/.profile" ;;
esac

if ! grep -q 'ENABLE_LSP_TOOL=1' "$RC_FILE" 2>/dev/null; then
  {
    echo ""
    echo "# ApexYard: enable Claude Code LSP (added by /setup)"
    echo "export ENABLE_LSP_TOOL=1"
  } >> "$RC_FILE"
  echo "✓ ENABLE_LSP_TOOL=1 added to $RC_FILE"
else
  echo "✓ ENABLE_LSP_TOOL=1 already present in $RC_FILE (no change)"
fi
```

Tell the operator they need to either open a new shell or `source "$RC_FILE"` for the env var to take effect in the **current** shell — `/setup` cannot mutate the parent shell's environment from its own subshell.

##### (d) Print the verified plugin-install commands

The Claude Code plugin-marketplace command shape (`/plugin marketplace add`, `/plugin install <name>@<marketplace>`, `/reload-plugins`) is empirically stable as of Claude Code 2.1.138 — verified end-to-end during me2resh/apexyard#215. The official Anthropic marketplace is `claude-plugins-official`; per-language plugin names come from the verified table at [code.claude.com/docs/en/discover-plugins](https://code.claude.com/docs/en/discover-plugins#code-intelligence).

The skill does **not** invoke these commands directly — `/plugin` is a Claude Code UI built-in, not a shell command, so a Bash call to it would silently no-op. The skill prints a copy-paste block for the operator to run inside Claude Code. Use the language → plugin map:

| Detected language | Plugin name |
|---|---|
| `typescript` | `typescript-lsp` |
| `python` | `pyright-lsp` |
| `go` | `gopls-lsp` |
| `rust` | `rust-analyzer-lsp` |

Print this block to the operator, substituting `{plugin-name}` for the detected language:

```
Final step — copy-paste these three commands into Claude Code (not the shell):

  /plugin marketplace add anthropics/claude-plugins-official
  /plugin install {plugin-name}@claude-plugins-official
  /reload-plugins

Then fully QUIT and RELAUNCH Claude Code (don't just /reload-plugins) so the
new shell inherits ENABLE_LSP_TOOL=1 from your rc file. /reload-plugins
reloads plugin state but does NOT re-read shell env, so the current Claude
Code process won't see the env var until you restart.

Verify after restart with `echo $ENABLE_LSP_TOOL` (should print 1).
```

**Always emit the `marketplace add` line.** The Anthropic docs claim `claude-plugins-official` is auto-loaded when Claude Code starts, but in practice the auto-add can be missing on a fresh install — operators who skip the `add` and run only `/plugin install` hit "Marketplace not found" and have to debug it themselves. The `add` is a no-op when the marketplace is already registered, so there's no downside to emitting it every time. **Do not** try to optimise it away based on a presumed-already-loaded check.

If a future Claude Code release changes the command shape, update the printed block here AND keep the docs URL above so a stale skill is recoverable from the link alone.

#### Step 2c.6 — Smoke test

After Steps 2c.5 (b)–(d), run a single smoke test that confirms the server binary is on PATH and reports next-session behaviour:

```bash
case "$DETECTED_LANG" in
  typescript) BIN=typescript-language-server ;;
  python)     BIN=pyright ;;
  go)         BIN=gopls ;;
  rust)       BIN=rust-analyzer ;;
esac

if command -v "$BIN" >/dev/null 2>&1; then
  echo "✓ $BIN installed at $(command -v $BIN)"
else
  echo "✗ $BIN not on PATH after install — see install errors above"
fi

echo "ℹ Next Claude Code session (with ENABLE_LSP_TOOL=1 in your shell environment) will use LSP."
```

The smoke test is **diagnostic only** — it does NOT block Step 3. If the server isn't on PATH, the operator gets a clear message and can fix it later; `/setup` shouldn't refuse to finish the bootstrap over an LSP install hiccup.

#### Step 2c.7 — Final summary line for this step

End Step 2c with a single status line capturing the outcome — used by Step 4's proposed-config summary so the operator can see at-a-glance what the skill changed:

```
LSP: server + env var configured ({detected-language} via {server-binary}, env var in {rc-file}); plugin-install commands printed for operator
LSP: already enabled on this machine — no changes
LSP: skipped (operator declined)
LSP: skipped (Windows — manual install required, see getting-started.md)
LSP: partial — server install or env var step failed (see above)
```

The "plugin-install commands printed" wording is accurate even after the empirically-verified copy-paste from Step 2c.5(d): the skill prints the three `/plugin …` commands but cannot invoke them itself (they're Claude Code UI built-ins, not shell commands), so the operator's copy-paste is the final piece.

Pick the line that matches the actual outcome. Don't claim "enabled" if any of (b)–(d) failed.

### Step 3: Parse and map to defaults

From the user's description, extract:

| Field | Parse from | Default if not mentioned |
|-------|-----------|------------------------|
| `company.name` | Company name in the description | Ask explicitly — this one's required |
| `company.mission` | What they're building | `""` (leave blank, user fills later) |
| `tech_stack.language` | "TypeScript", "Python", "Go", etc. | `"TypeScript"` |
| `tech_stack.framework` | "React", "Vue", "Svelte", etc. | `""` (no frontend) |
| `tech_stack.backend` | "Express", "FastAPI", "SAM", etc. | Inferred from language |
| `tech_stack.database` | "PostgreSQL", "DynamoDB", "MongoDB", etc. | `""` |
| `tech_stack.hosting` | "AWS", "GCP", "Azure", "Vercel", etc. | `"AWS"` |
| `project_management.tool` | "GitHub Issues", "Linear", "Jira" | `"GitHub Issues"` |
| `quality.required_checks` | Inferred from stack | `[lint, typecheck, test, build]` |
| `team` | Team size / roles mentioned | Minimal default (1 tech lead) |

Also infer non-obvious settings:

- If they mention "SAM" → `tech_stack.iac: "AWS SAM"` and add `sam validate --lint` to implied checks
- If they mention "Terraform" → `tech_stack.iac: "Terraform"` and add `terraform validate`
- If they mention "no frontend" or don't mention a framework → `workflows.require_design_review: false` (no UI = no design gate)
- If they mention "solo" or "1 person" → simplify team to just them, `required_reviews: 0`

### Step 4: Present the proposed config

Show a clean summary (NOT raw YAML — a formatted table or bulleted list):

```
Based on your description, here's how I'd configure your fork:

Company: ApexScript
Stack: TypeScript + React (frontend), AWS SAM + DynamoDB (backend)
Hosting: AWS
CI checks: npm run lint, npm run typecheck, npm run test, npm run build, sam validate --lint
Tracker: GitHub Issues, 1-week sprints
Reviewers: Rex (code-reviewer agent) + you
Quality: 80% coverage target, thorough review style
Team: 1 tech lead (you)

Design review gate: ON (React = UI work)
AgDR gate: ON (default architecture paths)
Commit types: framework defaults (feat, fix, refactor, test, docs, chore, style, perf, build, ci, revert)
LSP: enabled (typescript via typescript-language-server, env var in ~/.zshrc, plugin: manual)

Use these defaults, or customize?
```

Include the Step 2c.7 status line verbatim if Step 2c ran. If `/setup --enable-lsp` was invoked (retrofit mode), the summary is just the single LSP status line — no other proposed-config fields, since those are already configured.

### Step 5: Confirm or customize

- **"yes" / "looks good" / "use defaults"** → proceed to Step 6.
- **"customize X"** → ask about the specific field, update, re-show the summary with the change highlighted, re-confirm.
- **"no, actually we use Y"** → re-parse, re-propose.

Don't loop more than twice. If the user keeps correcting, switch to "tell me exactly what to change" direct-edit mode.

### Step 6: Write onboarding.yaml + the .apexyard-fork marker

**First, ensure a real `onboarding.yaml` exists to edit (#517).** The real config is now GITIGNORED; a fresh fork ships only the tracked `onboarding.example.yaml` placeholder template. So if `onboarding.yaml` is absent, copy the example to it before editing:

```bash
ONBOARDING=$(portfolio_onboarding_path)
EXAMPLE="$(dirname "$ONBOARDING")/onboarding.example.yaml"
[ -f "$ONBOARDING" ] || cp "$EXAMPLE" "$ONBOARDING"
```

Then read `onboarding.yaml` (single-fork: fork root; v2 split-portfolio: the private sibling repo, resolved via `portfolio_onboarding_path`), replace placeholder values with the confirmed config, and write back. Preserve the file's structure and comments — the comments are documentation for future readers.

**Important:** use `Edit` tool to modify in-place, not `Write` to overwrite — this preserves comments and structure that the user didn't touch.

In **single-fork mode** also write the `.apexyard-fork` marker at the fork root if it doesn't already exist (idempotent — content is ignored, presence is the signal):

```bash
if [ ! -f .apexyard-fork ]; then
  echo "# This file marks the directory as an ApexYard ops fork." > .apexyard-fork
  git add .apexyard-fork
fi
```

The marker is the v2 ops-fork anchor — every hook that walks up to find the ops fork looks for it first. Single-fork adopters benefit from the same anchor (cheaper presence test, and consistency with v2 split-portfolio adopters). The legacy `onboarding.yaml + apexyard.projects.yaml` walk remains as a fallback for un-migrated forks (so existing tests + un-migrated single-fork installs keep working without a migration).

In **split-portfolio v2 mode** the marker was already written in Step 2b — skip the bash above.

After writing:

```bash
# #517: onboarding.yaml is GITIGNORED in single-fork mode — it stays LOCAL and
# must NOT be staged/committed (the block-onboarding-in-git.sh guard backstops
# this). In v2 mode the real config lives in the PRIVATE sibling repo, where it
# is committed (the sibling is private), so staging there is fine.
ONBOARDING=$(portfolio_onboarding_path)
case "$ONBOARDING" in
  "$(git rev-parse --show-toplevel)"/*)
    : # single-fork — do NOT stage onboarding.yaml; it's gitignored, kept local
    ;;
  *)
    # v2 mode — onboarding lives in the PRIVATE sibling repo. Stage it there
    # so the user can `git -C ../<sibling> diff --cached` before committing.
    sibling_root=$(git -C "$(dirname "$ONBOARDING")" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$sibling_root" ]; then
      (cd "$sibling_root" && git add onboarding.yaml)
    fi
    ;;
esac
```

In **single-fork mode** the config is intentionally NOT committed — tell the user:

```
onboarding.yaml written locally (it's gitignored — your real config stays on
this machine and is never published to the public fork or an upstream PR).
Nothing to commit. If a teammate needs the config SHAPE, edit and commit
onboarding.example.yaml instead.
```

In **v2 split-portfolio mode** the real config is committed in the private sibling repo — point the user there for the diff + commit:

```
onboarding.yaml updated and staged in the private portfolio repo. Review with
`git -C ../<sibling> diff --cached` and commit when you're happy.
```

### Step 7: Optionally seed the project registry

If the user mentioned a specific project in their description, offer to add it:

```
You mentioned a property management SaaS. Want me to register it as
your first managed project in apexyard.projects.yaml?
I'll need: repo name (owner/repo) and a short project name.
```

If yes → append to `apexyard.projects.yaml`, stage alongside `onboarding.yaml`.
If no → skip. They can add projects later with `/handover`.

### Step 7a: Single-fork agent-routing seeding (advisory)

For **single-fork mode** only — split-portfolio adopters already got `agent-routing.yaml` seeded into the private repo in Step 5.

The framework ships `<fork>/agent-routing.yaml.example` as the worked-examples file, and `.gitignore` already has `/agent-routing.yaml` excluded so adopters can edit locally without leaking overrides to the public fork. By default `/setup` does NOT auto-copy the example to `agent-routing.yaml` — single-fork adopters' overrides shouldn't accumulate before they've made any. Mention the path explicitly so the operator knows where to start when they want to customise:

```
Agent routing (model + endpoint per agent) is in agent-routing.yaml at the
fork root. The framework ships `agent-routing.yaml.example` as a template;
`.gitignore` already excludes the working `agent-routing.yaml` file so
your overrides never leak to the public fork. When you're ready to
customise, run:

  cp agent-routing.yaml.example agent-routing.yaml
  $EDITOR agent-routing.yaml

The SessionStart sync hook (apply-agent-routing.sh) reads it on every
session start. See docs/multi-project.md § "Centralised agent routing".
```

No file writes here — purely informational. Added in #351 PR 3.

### Step 8: Clear the bootstrap marker (REQUIRED)

```bash
rm -f .claude/session/active-bootstrap
```

Always remove the marker on a clean exit so subsequent edits in the same session go through the normal ticket gate. If `/setup` is interrupted before this step, `clear-bootstrap-marker.sh` (SessionStart hook) clears the stale marker on the next session.

## Rules

1. **One question to start.** Do not ask about company, then stack, then team, then tools separately. One open-ended prompt, one natural-language response, one proposed config.
2. **Propose, don't interrogate.** Show the full config with sensible defaults and let the user correct. Most fields have obvious defaults from the description.
3. **Stage, don't commit.** The user should see the diff before it's committed. `/setup` stages; the user commits.
4. **Preserve structure.** `onboarding.yaml` has comments that explain each section. Don't blow them away — edit in place.
5. **Idempotent.** Running `/setup` again shows current config and asks what to update. Running with `--reset` clears and re-asks. Running with `--enable-lsp` retrofits the LSP step on an already-configured fork; if LSP is already enabled it's a no-op.
6. **No project-config.json.** `/setup` configures the FRAMEWORK (onboarding.yaml). Per-project config is handled by `/handover` and `/idea` when projects enter the portfolio.
7. **Never auto-install language runtimes.** Step 2c installs LSP servers (e.g. `typescript-language-server`, `pyright`, `gopls`, `rust-analyzer`) but never the underlying runtime (`node`, `python`, `go`, `rustup`). If a runtime is missing, refuse the LSP install gracefully and tell the operator what to install.
8. **Print plugin-install commands; never invoke them.** The Claude Code plugin marketplace command shape (`/plugin marketplace add`, `/plugin install`, `/reload-plugins`) is empirically stable — Step 2c.5(d) prints a copy-paste block for the operator. But `/plugin` is a Claude Code UI built-in, not a shell command, so the skill never runs the commands itself — it prints them. Always emit the `marketplace add` line; it's idempotent and recovers the case where the docs' auto-load claim doesn't fire on a fresh install.

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

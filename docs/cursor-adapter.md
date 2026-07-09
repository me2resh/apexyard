# Cursor Adapter

ApexYard's canonical runtime still lives in `.claude/`: skills, agents, hooks,
rules, and hook wiring are authored there first. Cursor support is generated
from that source of truth so the two agent surfaces do not drift by hand —
the same declarative-generate pattern as the [Codex adapter](codex-adapter.md).

Decision record: [`AgDR-0091`](agdr/AgDR-0091-cursor-adapter-generation.md).
Precedent: [`AgDR-0088`](agdr/AgDR-0088-codex-adapter-generation.md) (Codex),
[`AgDR-0082`](agdr/AgDR-0082-pi-gate-dispatcher-adapter.md) (pi).

> **Install at the USER level, not the project level (me2resh/apexyard#840).**
> Live testing against Cursor.app 3.10.20 found that Cursor 3.x's real hook
> loader reads `~/.cursor/hooks.json` (the USER config) — a project
> `.cursor/hooks.json` shows `Configured Hooks (0)` and is never loaded, no
> trust prompt. Use **`bin/install-cursor-adapter.sh`** (below) to install for
> real. The project-scoped generation this page describes further down
> (`bin/sync-cursor-adapter.sh` with no `--user` flag) still works and is kept
> available — for inspection, for a future Cursor version that may read
> project-level config, or for adopters who want to track the generated file
> in git — but it will not be loaded by a current Cursor.app session on its
> own.

**Where Cursor stands among the four third-party adapters.** opencode and pi
are both live-proven — their CLIs genuinely execute the delegated extension
code. Codex carried the same "live conformance unverified" caveat as Cursor
when its own AgDR (AgDR-0088) was written, but live testing has since closed
that gap (it turned out to be a trust-prompt issue, resolved via
`--dangerously-bypass-hook-trust` / a user-level trust grant) — Codex is now
live-proven too. **Cursor is the sole remaining outlier**: see "Known
Limitations" below for exactly what "enforced" means on Cursor today.

## Install (the path that actually loads in Cursor 3.x)

```bash
bin/install-cursor-adapter.sh
```

This merges the generated hooks into `~/.cursor/hooks.json` (override with
`--user-dir <path>`) and refreshes the project-level
`.cursor/rules/apexyard.mdc` advisory bridge in `--root` (defaults to this
script's own repo). The merge is additive and safe to re-run: any hook
already in `~/.cursor/hooks.json` that this framework did not generate — the
user's own, or a different tool's — is left alone. Only apexyard's own
entries (identified structurally: every one execs a `.claude/hooks/*.sh`
script) are replaced, so re-running after a `.claude/hooks/*.sh` upgrade
doesn't accumulate duplicates. A timestamped backup of the pre-merge file is
written before every overwrite.

```bash
bin/install-cursor-adapter.sh --uninstall
```

Removes only apexyard's own entries from `~/.cursor/hooks.json`, leaving
everything else in that file untouched. Also backed up first.

**Scope note.** Unlike the pi/opencode adapters (installed per-project into
that project's `.pi/extensions/` or `.opencode/plugins/`), this is a
per-machine (per-OS-user) install — Cursor's hook loader reads one
`~/.cursor/hooks.json` and applies it across every project you open in
Cursor. That's safe here because every generated hook command still
self-scopes: it resolves ops-root by walking up from Cursor's cwd for an
`.apexyard-fork` marker and exits 0 immediately if the current project isn't
apexyard-governed — installing once does not force apexyard's gates onto
unrelated Cursor projects.

**`cursor-agent` (the CLI) is NOT covered by this adapter.** Live testing
confirmed `cursor-agent` ignores `hooks.json` entirely — it enforces via its
own `~/.cursor/cli-config.json` `permissions.allow`/`deny` model instead. A
CLI-targeting adapter (translating apexyard's gates into
`cli-config.json` permissions) is out of scope here and would be separate
future work. Only the Cursor IDE agent (Cursor.app / Composer) is addressed
by `hooks.json`.

## Generate The Project-Level Adapter (kept available, not the load-bearing path)

```bash
bin/sync-cursor-adapter.sh
```

The command emits:

- `.claude/settings.json` → `.cursor/hooks.json`
- a static `.cursor/rules/apexyard.mdc` advisory bridge

It does **not** copy `.claude/hooks/` into `.cursor/`, and it does not mirror
`.claude/skills/` or `.claude/agents/` the way the Codex adapter does — Cursor
has no equivalent slash-command or agent-config surface in scope for this
adapter (see AgDR-0091 § Scope). The generated `hooks.json` keeps commands
that exec the unmodified `.claude/hooks/*.sh` scripts, so gate decisions,
session markers, review markers, and trust-chain path checks stay in the same
audited bash files every harness delegates to.

Both scripts share the exact same jq generation pipeline — `--user` (and
`install-cursor-adapter.sh`, which drives it) doesn't fork the gate logic,
it changes only where the result is written: merged into
`<--user-dir>/hooks.json` instead of copied to `<--root>/.cursor/hooks.json`.
See `bin/sync-cursor-adapter.sh --help` for the full flag set.

## Event Mapping

Cursor's hook vocabulary (`beforeShellExecution`, `preToolUse`,
`postToolUse`, `sessionStart`, `beforeSubmitPrompt`, …) does not name-match
Claude Code's (`PreToolUse`, `PostToolUse`, `SessionStart`,
`UserPromptSubmit`). The generator maps each `.claude/settings.json` matcher
group to the closest Cursor event:

| `.claude/settings.json` | Cursor event | Matcher | Notes |
|---|---|---|---|
| `PreToolUse` / `Bash` | `beforeShellExecution` | — | stdin remap (below) |
| `PreToolUse` / `Edit\|Write\|MultiEdit`, `Write` | `preToolUse` | `Write` | passthrough |
| `PreToolUse` / `Read\|Glob\|Grep` | `preToolUse` | `Read\|Grep` | passthrough |
| `PostToolUse` / `Bash` | `postToolUse` | `Shell` | passthrough |
| `PostToolUse` / `Write\|Edit\|MultiEdit` | `postToolUse` | `Write` | passthrough |
| `SessionStart` | `sessionStart` | — | passthrough |
| `UserPromptSubmit` | `beforeSubmitPrompt` | — | passthrough |

Cursor's tool-type matcher values are `Shell`, `Read`, `Write`, `Grep`,
`Delete`, `Task` — coarser than Claude Code's `Edit` / `Write` / `MultiEdit`
split. Both `Edit` and `MultiEdit` fold into Cursor's `Write` matcher. This is
a known conformance gap, not a bug: a hook that behaves differently for an
`Edit` vs. a `MultiEdit` call cannot be reproduced 1:1 under Cursor's coarser
taxonomy. None of the current `Edit|Write|MultiEdit`-matched hooks branch on
which specific tool fired, so the gap is latent today.

## Stdin Remap — `beforeShellExecution`

Cursor's `beforeShellExecution` event puts the shell command at the
**top level** of its stdin payload (`{"command": "...", "cwd": "...",
"sandbox": ...}`). Every `.claude/hooks/*.sh` script parses Claude Code's
stdin shape instead (`{"tool_name": "Bash", "tool_input": {"command": "..."}}`).
The generator closes that gap with a thin remap shim embedded in each
generated `beforeShellExecution` command:

1. Read the top-level `command` field from Cursor's stdin.
2. If the original Claude Code hook had a handler-level `if: "Bash(glob)"`
   predicate, apply the same glob as a shell `[[ == ]]` preflight filter
   (absent `if` — an unconditional Bash hook — is treated as glob `*`, so
   unconditional hooks are still remapped and still run on every shell call).
3. Re-wrap the command into `{"tool_name":"Bash","tool_input":{"command":…}}`
   and pipe it into the unmodified `.claude/hooks/<name>.sh`.
4. The hook's exit code propagates unchanged.

Unlike the Codex adapter (which needed a JSON `permission` translation),
Cursor treats **exit code 2 as a native deny** — "Exit code 2 blocks the
action (equivalent to returning `permission: "deny"`)" per the [Cursor hooks
docs](https://cursor.com/docs/hooks) — so the remap is the only shape
translation required; no exit-code translation is needed.

`preToolUse` / `postToolUse`-mapped hooks (Edit/Write/Read family) get no
remap: Cursor's own `tool_name`/`tool_input` shape for those events is
already the closest match to what the bash hooks parse, so those entries are
passed through unchanged. The Cursor-native field names inside `tool_input`
for non-Shell tools are not publicly documented beyond the base
`tool_name`/`tool_input` envelope, so live-Cursor conformance for that path
is unverified — see "Known Limitations" below.

## `failClosed` — Security-Critical Gates

Cursor hooks default to **fail-open**: `"failClosed": false` (or omitted)
means a crashed or timed-out hook lets the action through. The generator
marks a fixed set of security-critical gates `"failClosed": true` so a hook
crash blocks instead of silently passing:

| Class | Hooks |
|---|---|
| Merge gates | `block-unreviewed-merge.sh`, `block-merge-on-red-ci.sh`, `require-design-review-for-ui.sh`, `require-architecture-review.sh` |
| Secrets scan | `check-secrets.sh` |
| Trust-chain / leak protection | `block-git-add-all.sh`, `block-main-push.sh`, `block-private-refs-in-public-repos.sh`, `block-onboarding-in-git.sh` |
| Migration blast-radius | `require-migration-ticket.sh` (added #840 B3 — schema/data migrations carry the same blast radius as a merge; see AgDR-0091's "Update (GH-840)" section) |

Every other hook (ticket-vocabulary format validators, ticket-first gates,
advisory banners) stays fail-open — same default Cursor ships and the same
posture those hooks already have under Claude Code today (they exit 0 on
their own internal errors). The list is defined as `FAIL_CLOSED_HOOKS` near
the top of `bin/sync-cursor-adapter.sh`; extend it there if a future hook
joins the security-critical class.

## Advisory Bridge — `.cursor/rules/apexyard.mdc`

The generator also writes a minimal Cursor project rule
(`.cursor/rules/apexyard.mdc`, `alwaysApply: true`) that tells the agent the
gates are mechanical (enforced by `.cursor/hooks.json`, not by this file),
lists the five load-bearing rules to know before starting work, and points
at `CLAUDE.md` and `.claude/rules/*.md` for the full detail. It intentionally
does not inline the framework's SDLC content — see AgDR-0091 for why the
gates carry the substance and the rule file stays a pointer.

## Drift Check

```bash
bin/sync-cursor-adapter.sh --check
```

Use `--check` when generated adapter files are present and you want to
verify they still match `.claude/`. It exits non-zero on drift and prints
the files that need regeneration.

## Clean Regeneration

```bash
bin/sync-cursor-adapter.sh --clean
```

Removes the existing generated `.cursor/` tree before regenerating it.
Useful after generator changes.

## Tracking Policy

Same as the Codex adapter: the generator and its tests are the durable
upstream contribution. The generated `.cursor/` output should not be
committed directly from a local run (it can contain no absolute paths by
construction, but treat it the same as any generated artifact). For local
exploration, add it to `.git/info/exclude`:

```gitignore
.cursor/
```

If an adopter wants to treat Cursor as an enforced governance surface,
review and trust the generated `.cursor/hooks.json` explicitly and consider
tracking the generated adapter plus enforcing `--check` in CI.

## Known Limitations

Live testing against a real Cursor.app 3.10.20 session and the `cursor-agent`
CLI (me2resh/apexyard#840) resolved some of what earlier revisions of this
page marked "unverified" and surfaced two new, more specific limitations.
Read this section before relying on the adapter for anything beyond "known
commands get blocked."

- **`cursor-agent` (the CLI) is not covered — confirmed, not just untested.**
  Live testing instrumented every generated hook to log on fire, then ran a
  benign command through `cursor-agent -p -f`: the command executed and
  **zero hooks fired**. `cursor-agent` does not read `hooks.json` at all; it
  enforces via its own `~/.cursor/cli-config.json` `permissions.allow`/`deny`
  model. Anything that looked like enforcement from the CLI in earlier,
  informal testing was that allowlist, not this adapter. Only the Cursor IDE
  agent (Cursor.app / Composer) is addressed here.
- **The IDE only loads the USER-level hooks.json, not project-level —
  confirmed.** A project `.cursor/hooks.json` (what `sync-cursor-adapter.sh`
  writes without `--user`) showed `Configured Hooks (0)` in Cursor.app
  3.10.20 — never loaded, no trust prompt. The identical file installed at
  `~/.cursor/hooks.json` showed `Configured Hooks (1)` and was enforced.
  `bin/install-cursor-adapter.sh` targets the correct location by default;
  see "Install" above. This was a location bug, not a schema bug — `version:
  1`, `beforeShellExecution`, and `failClosed` were already correct.
- **Enforcement observed so far is `failClosed`, not confirmed clean
  delegated execution.** With the adapter loaded at the user level, a real
  agent turn's `git add .` was blocked and nothing staged — the gate held.
  But the delegated bash hook's own instrumentation (a log write on fire)
  never fired, and the agent reported `MainThreadShellExec not initialized`
  when asked to explain the block — it sourced its explanation by grepping
  `block-git-add-all.sh`, not from execution output. The most defensible
  read: Cursor's hook-runner could not cleanly exec the delegated bash
  command in this version, and `failClosed: true` denied the action because
  the hook errored — not because the gate logic evaluated and returned exit
  2. This is **weaker than the opencode/pi adapters**, where the delegated
  bash genuinely runs: (a) a command a gate would *allow* may also fail
  closed and get blocked incorrectly, and (b) the block doesn't prove the
  gate's actual decision logic ran. Whether `beforeShellExecution` can
  cleanly exec an external script in Cursor's agent mode at all, or whether
  this is a hard limitation of the current release, is an open investigation
  — not yet filed as a separate tracked follow-up as of this writing. Treat
  this adapter as "known-bad commands get blocked" until that's resolved,
  not as "the gate logic runs and you can trust an allow."
- **`preToolUse`/`postToolUse` field-name conformance is still unverified.**
  The live docs confirm `tool_input.command` for the `Shell` matcher (which
  this adapter avoids by using `beforeShellExecution` instead) but do not
  document the exact `tool_input` field names Cursor's own `Write`/`Read`
  tools use, and the live IDE test above did not exercise this path. Hooks
  delegated through `preToolUse`/`postToolUse` (the ticket-first gate,
  `maintain-docs-index.sh`, etc.) may receive a differently-shaped
  `tool_input` than the `.claude/hooks/*.sh` scripts expect.
- **Model pinning is out of scope.** Cursor hook generation does not need
  agent model-tier pinning the way the Codex adapter does (Codex agents run
  under `.codex/agents/*.toml` with a translated model label). This adapter
  does not add a `cursor` column to `.claude/harness-models.json`.

## Design Notes

- `.claude/` remains the source of truth.
- Generated files must not contain absolute paths to the local clone.
- Hook, rule, session, and review-marker references stay pointed at
  `.claude/...` because those files remain canonical and audited.
- The generator is intentionally plain Bash plus `jq`, matching the rest of
  the framework's hook/test toolchain and the Codex adapter's own approach.

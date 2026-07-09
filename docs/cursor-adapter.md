# Cursor Adapter

ApexYard's canonical runtime still lives in `.claude/`: skills, agents, hooks,
rules, and hook wiring are authored there first. Cursor support is generated
from that source of truth so the two agent surfaces do not drift by hand —
the same declarative-generate pattern as the [Codex adapter](codex-adapter.md).

Decision record: [`AgDR-0091`](agdr/AgDR-0091-cursor-adapter-generation.md).
Precedent: [`AgDR-0088`](agdr/AgDR-0088-codex-adapter-generation.md) (Codex),
[`AgDR-0082`](agdr/AgDR-0082-pi-gate-dispatcher-adapter.md) (pi).

## Generate The Adapter

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

- **Live-Cursor conformance is unverified.** This repository's bash smoke
  test (`.claude/hooks/tests/test_sync_cursor_adapter.sh`) proves command
  delegation, the stdin remap, and exit-code preservation entirely inside a
  synthetic fixture — it does not prove a real Cursor session actually loads
  `.cursor/hooks.json`, fires `beforeShellExecution` on every shell command,
  or blocks a real `gh pr merge` attempt end-to-end. A live-Cursor
  conformance test (a real Cursor session driving `gh pr merge` against
  `block-unreviewed-merge.sh` and observing the deny) is a tracked follow-up,
  same gap the Codex adapter carries today.
- **`preToolUse`/`postToolUse` field-name conformance is unverified.** The
  live docs confirm `tool_input.command` for the `Shell` matcher (which this
  adapter avoids by using `beforeShellExecution` instead) but do not document
  the exact `tool_input` field names Cursor's own `Write`/`Read` tools use.
  Hooks delegated through `preToolUse`/`postToolUse` (the ticket-first gate,
  `maintain-docs-index.sh`, etc.) may receive a differently-shaped
  `tool_input` than the `.claude/hooks/*.sh` scripts expect until this is
  verified against a real session.
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

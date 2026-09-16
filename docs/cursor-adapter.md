# Cursor Adapter

ApexYard's canonical runtime lives in `.claude/`. Cursor 3.10.20 loads that
runtime when third-party configs are on. The generated overlay does not copy
the Claude Code gates. It only maps Cursor `session_id` onto
`CLAUDE_CODE_SESSION_ID` so the ops-root pin works.

Decision record: [`AgDR-0151`](agdr/AgDR-0151-native-first-cursor-overlay.md).
History of the retired full copy: [`AgDR-0091`](agdr/AgDR-0091-cursor-adapter-generation.md).

## Native load (the load-bearing path)

Enable **Settings → Rules, Skills, Subagents → Include third-party Plugins,
Skills, and other configs**. Cursor then loads `.claude/settings.json` and
executes the unmodified `.claude/hooks/*.sh` scripts.

A live probe on Cursor.app 3.10.20 (2026-09-16) observed that path. A Write
call hit `require-active-ticket.sh` and returned the real ticket-first
message. Native exec is observed, not inferred.

Do not keep a leftover full generated adapter in `~/.cursor/hooks.json`.
That copy can fail-closed-block every Shell and Write call.

## Install the overlay

```bash
bin/install-cursor-adapter.sh
```

This merges one `sessionStart` overlay into `~/.cursor/hooks.json`. It also
refreshes `.cursor/rules/apexyard.mdc`. Foreign hooks stay. Leftover
apexyard-owned copies (any command that execs `.claude/hooks/*.sh`) are
replaced. A timestamped backup is written first.

```bash
bin/install-cursor-adapter.sh --uninstall
```

Removes only apexyard's own entries. Foreign hooks stay.

**Scope.** This is a per-machine install. The overlay self-scopes. It walks
for `.apexyard-fork`, or the legacy `onboarding.yaml` plus
`apexyard.projects.yaml` pair, and prints `{}` when the current project is
not governed.

**`cursor-agent` (the CLI) is not covered.** It ignores `hooks.json`. It
uses `~/.cursor/cli-config.json` permissions instead.

## Generate the project overlay

```bash
bin/sync-cursor-adapter.sh
```

The command emits:

- `.cursor/hooks.json` with one `sessionStart` command
- `.cursor/rules/apexyard.mdc`

Project command: `.claude/hooks/cursor-session-pin.sh`.
User-level command: walk to ops-root, then exec the same script.

The generator does not read `.claude/settings.json`. Gate lists stay in
that file. Cursor loads them natively.

```bash
bin/sync-cursor-adapter.sh --check
bin/sync-cursor-adapter.sh --clean
bin/sync-cursor-adapter.sh --user --check
```

## Session pin overlay

Cursor sessionStart stdin carries `session_id` or `conversation_id`.
Canonical hooks look up `CLAUDE_CODE_SESSION_ID`.
`.claude/hooks/cursor-session-pin.sh` closes that gap:

1. Read the Cursor session id from stdin.
2. Walk to the ops root.
3. Export `CLAUDE_CODE_SESSION_ID` and run `pin-ops-root.sh`.
4. Print `{"env":{"CLAUDE_CODE_SESSION_ID":"..."}}` or `{}`.

The overlay omits `failClosed`. A crash does not lock the session.

## Advisory bridge

`.cursor/rules/apexyard.mdc` (`alwaysApply: true`) tells the agent that
gates are mechanical. It lists the load-bearing rules. It points at
`CLAUDE.md` and `.claude/rules/*.md`. It does not inline the SDLC.

## Tracking policy

The thin overlay may be committed. It has no secrets and no absolute
paths. Clones then get project sessionStart without a generate step.

`--check` still detects overlay drift.

## Known limitations

- **Third-party configs must be on.** Without that toggle, `.claude/settings.json` does not load.
- **A leftover full adapter still locks the IDE.** Re-install or uninstall it.
- **`cursor-agent` CLI is not covered.** Confirmed. It ignores `hooks.json`.
- **Session env injection is not independently proven.** The overlay prints Cursor sessionStart `env` JSON. If Cursor does not apply it, later hooks walk from cwd as they already do.
- **Conformance CI has no headless Cursor path.** Cursor stays documented-manual on that badge.
- **Project vs user load can both fire the overlay.** That is one session-pin script, not 86 gates. Double pin writes are idempotent.

## Design notes

- `.claude/` remains the source of truth for gate logic.
- Generated files must not contain absolute paths to the local clone.
- The overlay exists only because Cursor names the session id differently.
- The generator is plain Bash plus `jq`.

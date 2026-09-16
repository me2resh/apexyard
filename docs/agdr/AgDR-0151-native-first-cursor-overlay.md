# Native-first Cursor overlay. Canonical gates stay in `.claude/`

> In the context of Cursor 3.10.20 loading `.claude/settings.json` natively, facing a leftover full generated adapter that fail-closed every Shell and Write call, I decided to stop copying the 86 Claude Code gates into `hooks.json`. Cursor now runs those gates from `.claude/settings.json`. The generated overlay only maps Cursor `session_id` onto `CLAUDE_CODE_SESSION_ID` and writes the ops-root pin. Adopters must enable third-party configs. A leftover full adapter is replaced on `--user` install.

## Context

AgDR-0091 generated a full event-mapped copy of `.claude/settings.json` into Cursor `hooks.json`. Live testing on 2026-07-09 found that Cursor 3.10.20 loaded only `~/.cursor/hooks.json`. Delegated bash did not appear to exec. `failClosed: true` blocked known-bad commands when the runner errored.

Official Cursor docs in 2026-09 state that project hooks load. They also state that Cursor loads Claude Code configs from `.claude/settings.json` when third-party Plugins, Skills, and other configs are enabled.

A live probe on this machine on 2026-09-16 used the same Cursor.app 3.10.20 build. After the user-level full adapter was removed and the window was reloaded, native Write hit `require-active-ticket.sh` and returned the real ticket-first message. Native exec of unmodified `.claude/hooks/*.sh` is therefore observed, not inferred.

The full user adapter still fail-closed the IDE when it was present. Empty output on every Shell and Write call matched `APEXYARD_CURSOR_HOOK_GLOB` plus `failClosed`. That copy is now a hazard, not a fallback.

`.claude/hooks/*.sh` still look up `CLAUDE_CODE_SESSION_ID`. Cursor sessionStart stdin carries `session_id` or `conversation_id`. Native SessionStart wrappers do not close that gap.

## Options Considered

| Option | Pros | Cons |
| --- | --- | --- |
| Keep generating the full 86-entry adapter | One install path. No native-loader toggle. | Double-fires with the native loader. `failClosed` can lock the session. Gate lists drift. |
| Uninstall Cursor hooks and rely on native load only | Smallest change. No overlay to maintain. | Ops-root pin never receives Cursor `session_id`. Later hooks fall back to a cwd walk. |
| Native-first plus a thin session-pin overlay | Gates have one source. Overlay fills the one Cursor-specific gap. `--user` merge strips leftover full copies. | Adopters must enable third-party configs. Overlay still needs a generate and install path. |

## Decision

Chosen: **native-first plus a thin session-pin overlay**.

Canonical gates stay in `.claude/settings.json` and `.claude/hooks/*.sh`. Cursor executes those files when third-party configs are on.

`bin/sync-cursor-adapter.sh` emits only:

- `.cursor/hooks.json` with one `sessionStart` command
- `.cursor/rules/apexyard.mdc` as an advisory pointer

The overlay command is `.claude/hooks/cursor-session-pin.sh` at project level. The user-level command walks to ops-root first because `~/.cursor` is not the repo.

The overlay does not set `failClosed`. A crash prints `{}` and lets the session continue. That matches Claude Code SessionStart fail-open posture.

`--user` merge still identifies apexyard-owned entries as any command that execs `.claude/hooks/*.sh`. Re-install replaces a leftover full adapter with the overlay. Foreign hooks stay.

`failClosed` on a named security list is retired for Cursor. Native Claude Code loading already owns those gates. Cursor `failClosed` was locking the IDE when the copied runner errored.

## Consequences

- Cursor IDE with third-party configs on runs the same unmodified bash gates as Claude Code.
- A leftover full `~/.cursor/hooks.json` copy can still lock the session until re-install or uninstall.
- `cursor-agent` CLI still ignores `hooks.json`. It is out of scope.
- Conformance CI still has no headless Cursor path. Cursor stays documented-manual there.
- Session pin depends on Cursor honoring sessionStart `env` JSON, or on the pin file plus a later `CLAUDE_CODE_SESSION_ID`. If neither lands, hooks walk from cwd as they already do.
- Regenerating after a pin-script change is still manual. `--check` still detects overlay drift.

## Artifacts

- Refs me2resh/apexyard#1311
- `.claude/hooks/cursor-session-pin.sh`
- `bin/sync-cursor-adapter.sh`
- `bin/install-cursor-adapter.sh`
- `.claude/hooks/tests/test_cursor_session_pin.sh`
- `.claude/hooks/tests/test_sync_cursor_adapter.sh`
- `.claude/hooks/tests/test_install_cursor_adapter.sh`
- Dated update on [AgDR-0091](AgDR-0091-cursor-adapter-generation.md)
- Precedent: AgDR-0091 (full generated adapter), AgDR-0086 (hooks stay bash)

## Evolution

Cursor support moved from a generated copy of every Claude Code gate to a native load of `.claude/` plus one session-pin overlay. The copy was the right shape when Cursor did not exec `.claude/settings.json`. It became a lock-the-session hazard once native exec was observed on Cursor 3.10.20. The overlay exists only because Cursor names the session id differently.

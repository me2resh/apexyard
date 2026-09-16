# Harness support — Cursor

**Status:** Native-first overlay ([AgDR-0151](../agdr/AgDR-0151-native-first-cursor-overlay.md)). Cursor.app 3.10.20 (2026-09-16) executed unmodified `.claude/hooks/*.sh` through the Claude Code loader after third-party configs were on and a leftover full adapter was removed. The generated overlay only maps Cursor `session_id` onto `CLAUDE_CODE_SESSION_ID`. The `cursor-agent` CLI is not covered.

The retired full copy is recorded in [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md). Install, generate, and drift-check steps live in **[`docs/cursor-adapter.md`](../cursor-adapter.md)**.

## What's enforced vs advisory today

**Cursor IDE, with third-party configs on.** Cursor loads `.claude/settings.json`. The same unmodified bash gates fire as under Claude Code. A live Write call on 2026-09-16 was refused by `require-active-ticket.sh`. The hook returned the real ticket-first message.

**Overlay (session pin only).** `.cursor/hooks.json` runs `.claude/hooks/cursor-session-pin.sh` on sessionStart. It does not copy merge gates, secrets scan, or ticket-first. It does not set `failClosed`.

**User-level merge still matters.** `bin/install-cursor-adapter.sh` writes the overlay into `~/.cursor/hooks.json`. Re-install strips leftover apexyard-owned copies. A leftover full adapter can fail-closed-block every Shell and Write call.

**`cursor-agent` CLI is not covered.** It ignores `hooks.json`. It uses `~/.cursor/cli-config.json` permissions.

**Advisory.** `.cursor/rules/apexyard.mdc` points at `CLAUDE.md` and `.claude/rules/*.md`.

## How it works (transport)

Cursor's Claude Code loader is the transport for gates. There is no stdin remap and no matcher table in the overlay.

The overlay closes one naming gap:

- Cursor sessionStart stdin carries `session_id` or `conversation_id`.
- Canonical hooks look up `CLAUDE_CODE_SESSION_ID`.
- `cursor-session-pin.sh` maps the id, writes the ops-root pin, and prints `env` JSON.

## How to install / generate

```bash
bin/install-cursor-adapter.sh             # merge overlay into ~/.cursor/hooks.json + refresh project rules
bin/install-cursor-adapter.sh --uninstall # remove only apexyard's entries from ~/.cursor/hooks.json

bin/sync-cursor-adapter.sh                # write project .cursor/hooks.json (sessionStart pin) + rules
bin/sync-cursor-adapter.sh --check        # verify generated project files still match
bin/sync-cursor-adapter.sh --user --check # verify installed USER overlay still matches
```

Enable Settings → Rules, Skills, Subagents → Include third-party Plugins, Skills, and other configs.

## Gaps + tracking

- SessionStart `env` injection into later hooks is not independently proven. Cwd walk remains the fallback.
- `cursor-agent` CLI adapter work is unscoped.
- Conformance CI has no headless Cursor path. Cursor stays documented-manual there.

## Related AgDRs

- [AgDR-0151](../agdr/AgDR-0151-native-first-cursor-overlay.md) — native-first overlay
- [AgDR-0091](../agdr/AgDR-0091-cursor-adapter-generation.md) — retired full generated adapter
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

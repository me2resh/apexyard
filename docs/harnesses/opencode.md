# Harness support — opencode

**Status:** Adapter **merged** (#821 → PR #839, [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md)); live opencode model-turn conformance pending (#821 remains open for exactly that AC).

opencode support is a **live TypeScript plugin** (opencode exposes an imperative plugin API rather than declarative hook config), but the governance stays single-source: the plugin is a thin transport that shells out to the **unmodified `.claude/hooks/*.sh`** and blocks the tool call when a hook exits `2`. Full install/usage in **[`docs/opencode-adapter.md`](../opencode-adapter.md)** (linked here, not duplicated).

## What's enforced vs advisory today

**Delegated (blocking, by construction):** on `tool.execute.before`, the plugin builds Claude-Code-shaped stdin, execs the matching bash hook, and **throws to deny** on exit 2 — the two-marker merge gate (all five wired merge-command shapes, including both #47 variants), red-CI block, ticket-first, secrets/leak-protection. Fail-closed is real: an execution-layer failure (spawn error, killed hook, no exit status) also denies. 43 hermetic unit tests plus a smoke script driving the real `block-unreviewed-merge.sh` to a genuine block back the transport.

**Gate derivation is drift-proof:** the plugin **derives its gate table from `.claude/settings.json` at load time** — no hand-maintained gate list. A new gate wired in `settings.json` reaches opencode automatically with zero adapter changes. (This is the convergence pattern the pi adapter is slated to adopt — see #840.)

**Advisory:** `AGENTS.md` carries the advisory governance bridge, per opencode's own convention.

## How it works (transport)

`harness-adapters/opencode/`:

- `src/derive-gates.ts` — parses `.claude/settings.json` PreToolUse wiring into the gate table at plugin init.
- `src/resolve-ops-root.ts` — the same ops-fork anchor-walk the hooks use; loading outside an apexyard fork is a clean no-op.
- `src/gate-dispatcher.ts` — builds `{"tool_name", "tool_input": {"command"|"filePath"}}` stdin, `execFile`s the hook (argv array, args via stdin only — no shell interpolation), throws on exit 2 or execution failure.

## How to install

See [`docs/opencode-adapter.md`](../opencode-adapter.md) — opencode auto-discovers local plugins under `.opencode/plugins/` (plural — see #844). Install via `bash bin/install-opencode-adapter.sh`, which writes the adapter into a subdirectory shape (`.opencode/plugins/apexyard/`) rather than a flat file copy; a flat copy crashes opencode at startup (#844).

## Gaps + tracking

- **Live model-turn conformance** — the transport is proven against the real hooks in-repo; a credentialed opencode session invoking `tool.execute.before` against this shipped dispatcher has not been recorded (spike #816 proved the pattern live against a throwaway prototype, not this code). That closing AC is why **#821 stays open**.
- Family hardening (bounded exec timeout, stdin for read-class tools, loud parse-failure warning): **#840**.

## Related AgDRs

- [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md) — opencode gate adapter; settings.json-derived gates over the bash hooks
- [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md) — the pi dispatcher precedent
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the plugin execs)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

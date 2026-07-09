# Harness support — opencode

**Status:** ✅ **Live-proven (2026-07-09)** — a real `opencode run --auto` model turn's `git add -A` was blocked by the delegated `block-git-add-all.sh` (verbatim hook output, nothing staged). Adapter merged (#821 → PR #839, [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md)); install shape hardened in #845.

## What's verified

A credentialed opencode session, run with `--auto`, issued `git add -A` during a real model turn and the delegated bash gate refused it — the same `.claude/hooks/block-git-add-all.sh` Claude Code runs, exit 2, nothing staged. This is the live end-to-end conformance proof the [rebrand trigger](README.md#rebrand-trigger) requires: not a mock, not a by-construction test. opencode is one of three adapters (with pi and Codex) that cleared that bar.

**How opencode reaches the gate:** it exposes an **imperative plugin API**, so the gate runs inside opencode's own `tool.execute.before` event during the real turn. Its precondition for enforcement is `--auto` (so the tool call reaches that event rather than being resolved through the approval flow first) — the opencode analog of pi's `-a` and Codex's hook-trust. The governance stays single-source: the plugin is a thin transport that shells out to the **unmodified `.claude/hooks/*.sh`** and blocks the tool call when a hook exits `2`. Full install/usage in **[`docs/opencode-adapter.md`](../opencode-adapter.md)** (linked here, not duplicated).

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

```bash
bash bin/install-opencode-adapter.sh
```

That writes the adapter into `.opencode/plugins/apexyard/` — a **subdirectory** shape, not a flat file copy. Both details are load-bearing and were confirmed live against opencode 1.17.16 (#844/#845):

- The discovery directory is **plural** — `.opencode/plugins/` — the singular `.opencode/plugin/` silently loads nothing.
- Every file must sit inside the one subdirectory behind a re-export `index.ts` shim; a flat `cp` of the adapter + its helper modules crashes opencode at startup, because opencode treats every exported function of a discovered file as a candidate plugin factory.

Full reference: [`docs/opencode-adapter.md`](../opencode-adapter.md).

## Preconditions

- **Run with `--auto`** (e.g. `opencode run --auto`). Without it, opencode resolves the shell action through its own approval flow and the tool call may never reach `tool.execute.before` — so the gate never fires. `--auto` is what let the live proof exercise the real hook.
- Loaded from inside an apexyard ops fork (the plugin's ops-root anchor-walk no-ops cleanly outside one).

## Gaps + tracking

- Family hardening (bounded exec timeout, stdin for read-class tools, loud parse-failure warning): **#840**.

## Related AgDRs

- [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md) — opencode gate adapter; settings.json-derived gates over the bash hooks
- [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md) — the pi dispatcher precedent
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md) — hooks stay bash (the source of truth the plugin execs)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard) — multi-project SDLC framework for Claude Code · MIT.*

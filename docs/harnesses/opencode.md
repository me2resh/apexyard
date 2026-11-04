# Harness support: opencode

**Status:** ✅ **Live-proven on opencode 2.1.4.** 2026-07-09: the delegated `block-git-add-all.sh` blocked a real `opencode run --auto` model turn's `git add -A` (verbatim hook output, nothing staged), on the then-current 1.x plugin API. 2026-11-04: on opencode 2.1.4 the V2 path blocked a real agent turn's fabricated `gh pr merge` through `block-unreviewed-merge.sh` (#1956). The V1 path is served again through `server()`, but it is covered by unit tests and a smoke script, not by a fresh live 1.x run. Adapter merged (#821 → PR #839, [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md)). Install shape hardened in #845.

## Supported plugin APIs

One package serves both generations. The default export carries `{ id, setup }` for opencode 2.x and a `server()` member for opencode 1.18.29+.

| opencode | API | Entry point | Tool ids |
|----------|-----|-------------|----------|
| 2.x | V2 | `setup(ctx)` → `ctx.tool.hook("execute.before", …)` | `shell`, `patch`, `edit`, `write`, `read`, `glob`, `grep` |
| 1.18.29+ | V1 | `server()` → `{ "tool.execute.before": … }` | `bash`, `apply_patch`, `edit`, `write`, `read`, `glob`, `grep` |

Both id sets are accepted on either runtime, so a gate cannot silently stop matching after an opencode upgrade. A configured local plugin path must be a **directory** in V2; a path to a single file is skipped with a log warning.

## Verification

A credentialed opencode session, run with `--auto`, issued `git add -A` during a real model turn. The delegated bash gate refused it with exit 2, and staged nothing. This is the live end-to-end proof required by the [rebrand trigger](README.md#rebrand-trigger), rather than a mock or a by-construction test. opencode is one of three adapters, with pi and Codex, that cleared that bar.

**How opencode reaches the gate:** it exposes an **imperative plugin API**, so the gate runs inside opencode's own pre-execution tool hook during the real turn (`execute.before` on V2, `tool.execute.before` on V1). Its precondition for enforcement is `--auto` (so the tool call reaches that hook rather than going through the approval flow first). That is the opencode analog of pi's `-a` and Codex's hook-trust. The governance stays single-source. The plugin is a thin transport that shells out to the **unmodified `.claude/hooks/*.sh`** and blocks the tool call when a hook exits `2`. Full install/usage in **[`docs/opencode-adapter.md`](../opencode-adapter.md)** (linked here, not duplicated).

## Enforcement vs advisory today

**Delegated (blocking, by construction):** on the pre-execution tool hook, the plugin builds Claude-Code-shaped stdin, execs the matching bash hook, and **throws to deny** on exit 2. That covers the two-marker merge gate (all five wired merge-command shapes, including both #47 variants), red-CI block, ticket-first, and secrets/leak-protection. Fail-closed is real. An execution-layer failure (spawn error, killed hook, no exit status) also denies. A `patch` call is routed through `dispatch-apply-patch.sh`, which re-runs every Edit/Write check once per target path, so a multi-file patch cannot step around those gates. 70 hermetic unit tests plus two smoke scripts (a genuine block from the real `block-unreviewed-merge.sh`, and the shipped install layout's V2 definition shape) back the transport.

**Gate derivation is drift-proof, with one named exception:** the plugin **derives its gate table from `.claude/settings.json` at load time**. There is no hand-maintained gate list, except the single patch-routing wire. That wire cannot come from `settings.json` (see `patchRoutingGates` in `src/gate-dispatcher.ts`), so it is added explicitly. The plugin also warns at init when the host registers a file-writing tool that no wire routes. A new gate wired in `settings.json` reaches opencode automatically with zero adapter changes. (This is the convergence pattern planned for the pi adapter. See #840.)

**Advisory:** `AGENTS.md` carries the advisory governance bridge, per opencode's own convention.

## How it works (transport)

`harness-adapters/opencode/`:

- `src/derive-gates.ts`: parses `.claude/settings.json` PreToolUse wiring into the gate table at plugin init.
- `src/resolve-ops-root.ts`: the same ops-fork anchor-walk the hooks use. Loading outside an apexyard fork is a clean no-op.
- `src/gate-dispatcher.ts`: builds `{"tool_name", "tool_input": {"command"|"file_path"}}` stdin from the V2 `{ tool, input }` event (or V1's `(input, output)`), `execFile`s the hook (argv array, args via stdin only: no shell interpolation), throws on exit 2 or execution failure. It also exports the dual `{ id, setup }` + `server()` plugin definition.

## How to install

```bash
bash bin/install-opencode-adapter.sh
```

That writes the adapter into `.opencode/plugins/apexyard/`: a **subdirectory** shape, not a flat file copy. Both details are load-bearing and had live confirmation against opencode 1.17.16 (#844/#845):

- The discovery directory is **plural**: `.opencode/plugins/`. V1's singular `.opencode/plugin/` silently loads nothing. V2 accepts both forms, and plural is its documented layout.
- Every file must sit inside the one subdirectory behind a re-export `index.ts` shim. A flat `cp` of the adapter + its helper modules crashed opencode 1.x at startup, because V1 treated every exported function of a discovered file as a candidate plugin factory. V2 validates only the `default` export, so that crash mode is gone. The layout is kept anyway, so a closed export surface stays a structural invariant.

Full reference: [`docs/opencode-adapter.md`](../opencode-adapter.md).

## Preconditions

- **Run with `--auto`** (e.g. `opencode run --auto`). Without it, opencode resolves the shell action through its own approval flow and the tool call may never reach `tool.execute.before`. So the gate never fires. `--auto` is what let the live proof exercise the real hook.
- Loaded from inside an apexyard ops fork (the plugin's ops-root anchor-walk no-ops cleanly outside one).

## Gaps + tracking

- Family hardening (bounded exec timeout, stdin for read-class tools, loud parse-failure warning): **#840**.

## Related AgDRs

- [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md): opencode gate adapter; settings.json-derived gates over the bash hooks
- [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md): the pi dispatcher precedent
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md): hooks stay bash (the source of truth the plugin execs)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

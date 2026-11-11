# Harness support: opencode

**Status:** ✅ **Live-proven on opencode 2.1.4.** 2026-07-09: the delegated `block-git-add-all.sh` blocked a real `opencode run --auto` model turn's `git add -A` (verbatim hook output, nothing staged), on the then-current 1.x plugin API. 2026-11-04: on opencode 2.1.4 the V2 path blocked a real agent turn's fabricated `gh pr merge` through `block-unreviewed-merge.sh` (#1956). `server()` serves the V1 path again. Unit tests and a smoke script cover it, not a fresh live 1.x run. Adapter merged (#821 → PR #839, [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md)). Install shape hardened in #845.

## Supported plugin APIs

One package serves both generations. The default export carries `{ id, setup }` for opencode 2.x and a `server()` member for opencode 1.3.4+. Running the release binaries verifies the 1.3.4 floor: 1.3.3 fails with `fn3 is not a function`, and 1.3.4 loads the object and calls `server()`.

| opencode | API | Entry point | Tool ids |
|----------|-----|-------------|----------|
| 2.x | V2 | `setup(ctx)` → `ctx.tool.hook("execute.before", …)` | `shell`, `patch`, `edit`, `write`, `read`, `glob`, `grep` |
| 1.3.4+ | V1 | `server()` → `{ "tool.execute.before": … }` | `bash`, `apply_patch`, `edit`, `write`, `read`, `glob`, `grep` |

The adapter accepts both id sets on either runtime, so a gate cannot silently stop matching after an opencode upgrade. V2 requires a configured local plugin path to be a **directory**. The loader skips a single-file path and logs a warning.

## Verification

A credentialed opencode session, run with `--auto`, issued `git add -A` during a real model turn. The delegated bash gate refused it with exit 2, and staged nothing. This is the live end-to-end proof required by the [rebrand trigger](README.md#rebrand-trigger), rather than a mock or a by-construction test. opencode is one of three adapters, with pi and Codex, that cleared that bar.

**How opencode reaches the gate:** opencode exposes an **imperative plugin API**. The gate therefore runs inside opencode's own pre-execution tool hook during the real turn (`execute.before` on V2, `tool.execute.before` on V1). Its precondition for enforcement is `--auto` (so the tool call reaches that hook rather than going through the approval flow first). That is the opencode analog of pi's `-a` and Codex's hook-trust. The governance stays single-source. The plugin is a thin transport that shells out to the **unmodified `.claude/hooks/*.sh`** and blocks the tool call when a hook exits `2`. Full install/usage in **[`docs/opencode-adapter.md`](../opencode-adapter.md)** (linked here, not duplicated).

## Enforcement vs advisory today

**Delegated (blocking, by construction):** the pre-execution tool hook builds Claude-Code-shaped stdin and execs the matching bash hook. The plugin **throws to deny** on exit 2. That covers the two-marker merge gate (all five wired merge-command shapes, including both #47 variants), red-CI block, ticket-first, and secrets/leak-protection. Fail-closed is real. An execution-layer failure (spawn error, killed hook, no exit status) also denies. The adapter routes a `patch` call through `dispatch-apply-patch.sh`. That script re-runs every Edit/Write check once per target path, so a multi-file patch cannot step around those gates. 84 hermetic unit tests plus two smoke scripts back the transport. One is a genuine block from the real `block-unreviewed-merge.sh`. The other checks the shipped install layout's V2 definition shape.

**Gate derivation is drift-proof, with one named exception:** the plugin **derives its gate table from `.claude/settings.json` at load time**. There is no hand-maintained gate list, except the single patch-routing wire. That wire cannot come from `settings.json` (see `patchRoutingGates` in `src/gate-dispatcher.ts`), so the adapter adds it explicitly. The plugin also warns at init when the host registers a file-writing tool that no wire routes. A new gate wired in `settings.json` reaches opencode automatically with zero adapter changes. (This is the convergence pattern planned for the pi adapter. See #840.)

**Advisory:** `AGENTS.md` carries the advisory governance bridge, per opencode's own convention.

## How it works (transport)

`harness-adapters/opencode/`:

- `src/derive-gates.ts`: parses `.claude/settings.json` PreToolUse wiring into the gate table at plugin init.
- `src/resolve-ops-root.ts`: the same ops-fork anchor-walk the hooks use. Loading outside an apexyard fork is a clean no-op.
- `src/gate-dispatcher.ts`: builds `{"tool_name", "tool_input": {"command"|"file_path"}, "cwd"}` stdin from the V2 `{ tool, input }` event (or V1's `(input, output)`). `cwd` is `ctx.location.directory` (V1: `input.directory`), and the hook subprocess runs there, so relative targets resolve against the tree opencode writes into. It `execFile`s the hook (argv array, args via stdin only: no shell interpolation) and throws on exit 2 or execution failure. It also exports the dual `{ id, setup }` + `server()` plugin definition.

## How to install

```bash
bash bin/install-opencode-adapter.sh
```

That writes the adapter into `.opencode/plugins/apexyard/`: a **subdirectory** shape, not a flat file copy. Both details are load-bearing and had live confirmation against opencode 1.17.16 (#844/#845):

- The discovery directory is **plural**: `.opencode/plugins/`. V1's singular `.opencode/plugin/` silently loads nothing. V2 accepts both forms, and plural is its documented layout.
- Every file must sit inside the one subdirectory behind a re-export `index.ts` shim. A flat `cp` of the adapter + its helper modules crashed opencode 1.x at startup. V1 treated every exported function of a discovered file as a candidate plugin factory. V2 validates only the `default` export, so that crash mode is gone. The layout stays anyway, so a closed export surface remains a structural invariant.

Full reference: [`docs/opencode-adapter.md`](../opencode-adapter.md).

## Preconditions

- **Run with `--auto`** (e.g. `opencode run --auto`). Without it, opencode resolves the shell action through its own approval flow and the tool call may never reach `tool.execute.before`. So the gate never fires. `--auto` is what let the live proof exercise the real hook.
- Loaded from inside an apexyard ops fork (the plugin's ops-root anchor-walk no-ops cleanly outside one).

## Limits of the Bash gates in opencode

The opencode plugin does not run `.claude/hooks/dispatch-bash.sh`.
It builds one gate per hook from the routing comments in that file and the entries in `.claude/settings.json`.
It matches the command text by its prefix, with the same matcher as the pi adapter.
Claude Code scans the whole command only for push, commit and merge commands (`.claude/hooks/dispatch-bash.sh:541-676`).
Its other Bash routes also match by prefix (`dispatch-bash.sh:479-515`).
The plugin has no whole-command scan at all.

- Some command shapes skip a gate in opencode. For example, `cd repo && gh pr merge 5` and `cd repo && git push` start with `cd`, so no merge gate and no push gate runs for them.
- A gate that crashes lets the call run. When a hook exits with a number other than 2, such as 1 or 127, the plugin allows the call. Only exit 2 blocks. A spawn error, a timeout or a kill signal does block.
- When `.claude/settings.json` does not parse, the plugin enforces no gates in that session. It prints a warning to stderr.

The text above that says fail-closed is real covers only an execution failure with no exit status.
See the [pi page](pi.md#limits-of-the-bash-gates-in-pi) for the same limits.

## Gaps + tracking

- Family hardening (bounded exec timeout, stdin for read-class tools, loud parse-failure warning): **#840**.

## Related AgDRs

- [AgDR-0092](../agdr/AgDR-0092-opencode-gate-adapter.md): opencode gate adapter; settings.json-derived gates over the bash hooks
- [AgDR-0082](../agdr/AgDR-0082-pi-gate-dispatcher-adapter.md): the pi dispatcher precedent
- [AgDR-0086](../agdr/AgDR-0086-hooks-stay-bash-not-ported.md): hooks stay bash (the source of truth the plugin execs)

---

*Part of [ApexYard](https://github.com/me2resh/apexyard): multi-project SDLC framework for Claude Code · MIT.*

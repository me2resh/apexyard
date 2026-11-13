# opencode Adapter

apexyard's governance initially targeted Claude Code. `CLAUDE.md` is auto-loaded at session start, `.claude/hooks/*.sh` mechanically enforce the merge gate / ticket-first / secrets-scan rules, and `.claude/skills/*.md` become typed slash commands. [opencode](https://opencode.ai) has a different shape: a plugin-extensible agent CLI with an `execute.before` tool hook. It has no built-in slash-command runner and no Claude-Code-style hook wiring of its own. **apexyard reaches opencode through a plugin that shells out to the same, unmodified `.claude/hooks/*.sh` scripts Claude Code uses**: one governance implementation, enforced under two harnesses.

This adapter **serves both plugin generations from one entrypoint**. opencode 2.x calls `setup(ctx)` on a definition object. opencode 1.3.4+ calls `server()` on that same object. The export is `{ id: "apexyard.gates", setup, server }`. 2.x rejects a bare V1 `async (input) => hooks` factory with `Plugin must export a default definition with an id and an effect or setup function`, so the object carries both members. Running the release binaries verifies the 1.3.4 floor: 1.3.3 fails with `fn3 is not a function`, and 1.3.4 loads the object and calls `server()`. See the tool-id table below for the per-generation vocabulary.

Decision record: [`AgDR-0092`](agdr/AgDR-0092-opencode-gate-adapter.md). Promoted from spike [me2resh/apexyard#816](https://github.com/me2resh/apexyard/issues/816) (verdict: VIABLE, proven fully live). Feature: me2resh/apexyard#821.

## What this enforces

The adapter (`harness-adapters/opencode/src/gate-dispatcher.ts`) derives its gate table from the ops fork's `.claude/settings.json` at plugin load. There is no hand-maintained gate list, with one named exception. The adapter adds a single patch-routing wire explicitly, because `settings.json` cannot express it. Codex reaches its `apply_patch` path through the `*` matcher and a `--shell-alias-only` flag that this adapter cannot pass. See `patchRoutingGates`. The derived table includes every hook wired to the `Bash`, `Edit`, `Write`, `MultiEdit`, `Read`, `Glob`, or `Grep` matchers. It includes the multi-tracker merge-shape variants (`gh pr merge`, `gh api .../merge`, `glab mr merge`, `glab api`, `tracker_pr_merge`). This was originally a deliberate upgrade over the sibling pi adapter (`harness-adapters/pi/`), which shipped a hand-written, curated `DEFAULT_GATES` table. pi has since converged to the same settings.json-derived pattern (#840 C5). See `harness-adapters/_shared/derive-gates-core.ts`, the parsing core the two adapters now share. See `harness-adapters/opencode/src/derive-gates.ts` for the full rationale, referred to throughout this framework as "the #730 convergence". The design review on the Codex adapter, #730, first named the risk: a hand-maintained gate table can silently drift from `.claude/settings.json`.

Concretely, the opencode adapter enforces the following non-exhaustive list. The list is whatever `.claude/settings.json` wires, not a fixed set. It includes the two-marker merge gate (`block-unreviewed-merge.sh`) and red-CI merge blocking (`block-merge-on-red-ci.sh`). It includes design and architecture review gates (`require-design-review-for-ui.sh`, `require-architecture-review.sh`), secrets scanning (`check-secrets.sh`), and leak protection (`block-private-refs-in-public-repos.sh`). It includes ticket-first and migration-ticket-first edit blocking (`require-active-ticket.sh`, `require-migration-ticket.sh`), and every other blocking `PreToolUse` hook the framework ships or an adopter adds. This happens automatically, with zero adapter changes required when the framework or an adopter wires a new gate.

## Slash commands

opencode discovers `.claude/skills` as a skill source. An agent can load a skill from it, but the tree never becomes operator-invocable slash commands: the `/` menu reads only `.opencode/commands/*.md` or a `commands` block in `opencode.json`. Under Claude Code the same files are both. `bin/sync-opencode-commands.sh` closes that half of the harness gap (me2resh/apexyard#2064):

```bash
bin/sync-opencode-commands.sh            # write or refresh, prune stale wrappers
bin/sync-opencode-commands.sh --check    # write nothing; exit 1 when out of date
```

It writes one wrapper per `.claude/skills/<id>/SKILL.md`, at `.opencode/commands/<id>.md`:

- The frontmatter `description:` is copied from the skill, with `argument-hint:` appended when the skill has one, so the `/` menu and the command palette show the same summary Claude Code shows.
- The body instructs the agent to load `<id>` with the skill tool and to forward `$ARGUMENTS`. The skill body therefore stays the single source of truth: prose edits need no regeneration, and only a `description:` or `argument-hint:` change does.
- Wrappers carry a generator marker, and only marked files are pruned. A hand-written `.opencode/commands/*.md` is never removed.
- `_lib-*` helpers, directories without a `SKILL.md`, and names that are not valid command IDs are skipped.

`.opencode/commands/` is gitignored. The wrappers are regenerable per machine and per fork, the same way the install script's `.opencode/plugins/apexyard/` is local. Run the generator once after installing the adapter, and again after any `/update` that changes skills. A fork that commits the wrappers instead can wire `--check` into CI.

Command names come from skill IDs, so they shadow any opencode built-in with the same name: `/status` is apexyard's status skill, not opencode's.

The `description:` frontmatter is emitted as a block scalar, so a skill description containing a colon, quotes, backticks, or an em dash needs no escaping.

Tests: `bash .claude/hooks/tests/test_sync_opencode_commands.sh`.

## Install

```bash
cd harness-adapters/opencode
npm install
cd ../..
bash bin/install-opencode-adapter.sh   # writes .opencode/plugins/apexyard/ in your CWD
bash bin/sync-opencode-commands.sh     # writes .opencode/commands/ (slash commands)
```

**The discovery directory is PLURAL: `.opencode/plugins/`, not `.opencode/plugin/`.** An earlier version of this doc claimed opencode's discovery glob accepted either form. That was wrong, confirmed live against opencode 1.17.16 in [me2resh/apexyard#844](https://github.com/me2resh/apexyard/issues/844). The singular form silently loads nothing.

Configured local plugin paths in `opencode.json` must be **directories** on V2. The loader skips a path to a single file and logs a warning. The install script already writes the directory shape the loader expects.

**Every adapter file must live inside one subdirectory, never flat in the discovery dir.** On opencode 1.x, the loader invoked EVERY exported function of a discovered file as a candidate plugin factory, not only its default export. `gate-dispatcher.ts` (the adapter's real implementation) exports several named helpers alongside its default plugin. With this file directly in `.opencode/plugins/`, opencode called each helper as if it might be a plugin. This crashed the whole server at startup (`Error: {"name":"UnknownError","message":"Unexpected server error"}`; also #844, live). V2 validates only the default export, so that crash mode is gone. The layout stays anyway. A closed export surface then remains a structural invariant, not a property that happens to hold for the current loader. `bin/install-opencode-adapter.sh` produces it by construction: it writes `.opencode/plugins/apexyard/index.ts`, a re-export shim whose ONLY export is the default plugin definition. It writes its helper modules as siblings inside that same subdirectory. opencode's subdirectory discovery only loads `index.ts` per subdir, so the helpers are never independently visited. See `harness-adapters/opencode/src/index.ts`'s header comment for the full mechanism, and `harness-adapters/opencode/README.md` for the script's `--target-dir`/`--root` options and the alternative `opencode.json` `plugins` config array install path.

## How it works

1. opencode 2.x loads the plugin's default export, a definition object `{ id: "apexyard.gates", setup }`. It calls `setup(ctx)` once per plugin instance with the V2 plugin `Context`. opencode 1.3.4+ instead calls `server(input)` on the same object, and the plugin uses the returned `{ "tool.execute.before" }` hooks.
2. The plugin resolves the apexyard ops root. It walks up from `ctx.location.directory` for an `.apexyard-fork` marker or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair. Alternatively, it uses an explicit `APEXYARD_OPS_ROOT` override. It derives the gate table from that ops root's `.claude/settings.json`.
3. It registers one hook with `ctx.tool.hook("execute.before", handler)`. On every matching tool call the plugin checks the call against the derived gate table. A matching gate runs its bash hook as a real subprocess with the reconstructed Claude-Code-shaped stdin (`{tool_name, tool_input, cwd}`). The top-level `cwd` is `ctx.location.directory` (V1: `input.directory`), and it is also the subprocess's working directory. `dispatch-apply-patch.sh` reads the field directly. `require-active-ticket.sh` resolves relative targets from the subprocess working directory. Without the field, they resolve a relative target against the ops root instead of the directory opencode writes into. When the session directory sits outside the ops root, the adapter falls back to the ops root. That covers `APEXYARD_OPS_ROOT` mode, where the bash checks need that root to find their own wiring.
4. Exit code `2` → the plugin **throws**. This is opencode's way to deny a tool call from this hook. There is no `{block: true}` return the way pi has. Any other numeric exit code → allow. No numeric exit status at all → the plugin throws and **fails closed**. This covers spawn failure, output over the buffer ceiling, and signal kill. The plugin names the hook and the underlying error rather than silently letting the tool call through.

Note the per-generation tool vocabulary. The command tool is `shell` on V2 and `bash` on V1. `edit`/`write` take the target file as `path` on V2 and `filePath` on V1. The V1 handler reads `filePath` only, so a decoy `path` beside it cannot redirect the check. The patch tool is `patch` on V2 and `apply_patch` on V1. The adapter accepts every id on either runtime. A gate wire fires only on an exact tool-id match, so a wrong id would leave every matching gate silent, with no error anywhere. That is a fail-open, which is the worst failure mode for a governance plugin. The adapter blocks a patch call with no envelope rather than skipping it, so a renamed argument cannot silently disable its target checks.

The adapter routes patch calls to `.claude/hooks/dispatch-apply-patch.sh`. That script re-runs every Edit/Write check once per target path, so a multi-file patch cannot step around the ticket-first, protected-target, or reviewer-marker gates. Before that wire existed, a V2 `patch` call ran no gate at all.

## Testing

```bash
cd harness-adapters/opencode
npm test               # hermetic unit tests: settings.json-derived gate matching,
                        # stdin construction, exit-2 -> throw mapping (subprocess exec mocked)
npm run typecheck      # verifies field-name assumptions against the real, installed
                        # @opencode/plugin V2 types
bash test/smoke-block-unreviewed-merge.sh   # real hook, real exec, fixture ops root, negative control
bash test/smoke-install-layout.sh           # real install layout: exports only `default`,
                                             # default is a V2 { id, setup } definition, and
                                             # setup registers an execute.before hook
```

## What the proof covers, and what remains: the honest breakdown

| Claim | Status |
|-------|--------|
| opencode's real V2 plugin API surface (`Plugin.Plugin` = `{ id, setup }`, `Context.location.directory`, `ctx.tool.hook("execute.before", …)`, the `{ tool, input }` event, the command tool's `shell` id and `command` field, `edit`/`write`'s `path` field) | **Verified**: against the real, installed `@opencode/plugin` package (`dist/promise/plugin.d.ts`, `dist/promise/tool.d.ts`; 2.2.5 resolved by the lockfile, with 2.1.4 as the declared floor). Verified again against the V2 tools documentation and opencode 2.1.4's live model-visible tool catalog. The claim does not rest on documentation alone. `npm run typecheck` re-verifies it on every run. |
| The gate table matches `.claude/settings.json`'s real wiring, including multi-tracker merge-shape globs | **Verified**: `derive-gates.test.ts` parses this repo's own real `.claude/settings.json` (not only a hand-written fixture). It asserts correct derivation of every named gate, plus the merge-gate's five glob variants. |
| A real, unmodified bash hook (`block-unreviewed-merge.sh`) blocks a fabricated merge command through the full dispatcher pipeline. The pipeline comprises settings.json parse → gate match → real subprocess exec → exit-code mapping | **Verified live**: `test/smoke-block-unreviewed-merge.sh` runs this against a fixture ops root with a real copy of `.claude/hooks/`. A negative control (no hook scripts present) proves the block is hook-driven, not unconditional. |
| A real, model-driven **opencode** agent turn invoking the hook with a matching event shape | **Verified live on opencode 2.1.4 (2026-11-04), against this shipped dispatcher.** A real agent session, with the plugin loaded from `.opencode/plugins/apexyard/` and no test harness, issued `gh pr merge 999999 --repo <nonexistent-fixture> --squash` through the `shell` tool. The unmodified `block-unreviewed-merge.sh` refused it with its own reason text. That exercises the whole live chain. The loader accepted the V2 definition and `setup` registered `execute.before`. opencode then dispatched a real `shell` tool call to the handler. `event.tool === "shell"` matched the derived wires, and `event.input.command` reached the hook. Spike #816 had proven the same pattern once under V1, against the throwaway prototype. |

### Live-verification history

**Closed for V2 (2026-11-04, opencode 2.1.4).** With the ported adapter installed from `.opencode/plugins/apexyard/`, a real agent session issued `gh pr merge 999999 --repo <nonexistent-fixture> --squash` through the `shell` tool. The unmodified `block-unreviewed-merge.sh` refused it with its own reason text. This repeats the verification spike #816 performed once against the throwaway V1 prototype, now against the shipped, settings.json-derived dispatcher under V2 registration.

**Still open**: a live end-to-end re-run under opencode 1.x. `server()` serves that path again, but this change exercised only the V2 dispatch path live. Unit tests cover the V1 hook shape.

## Relationship to the pi and Codex adapters

| Adapter | Gate source | Mechanism |
|---------|-------------|-----------|
| `harness-adapters/pi/` | **Derived from `.claude/settings.json` per `tool_call` event** (AgDR-0082's "Update (GH-840)") | Dispatcher extension, `tool_call` event, `{block, reason}` return |
| `bin/sync-codex-adapter.sh` (Codex) | Generated from `.claude/settings.json` at build time (AgDR-0088) | Static `.codex/hooks.json`, predicates compiled into the generated command |
| `harness-adapters/opencode/` (this adapter) | **Derived from `.claude/settings.json` at plugin load time** | Dispatcher plugin, `execute.before` hook (V2), throw-to-deny |

All three converge on the same underlying principle established by AgDR-0086 ("hooks stay bash, not ported"). `.claude/hooks/*.sh` remains the single source of truth for every gate decision. Every harness reaches it through a thin transport layer rather than a reimplementation. This adapter's contribution closes the "gate table can drift from settings.json" gap pi originally carried. pi now also includes this contribution (#840 C5), sharing the settings.json-parsing core (`harness-adapters/_shared/derive-gates-core.ts`) between the two. Each adapter keeps its own runtime-specific tool-vocabulary translation and `buildToolInput`.

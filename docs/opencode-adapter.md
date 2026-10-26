# opencode Adapter

apexyard's governance initially targeted Claude Code. `CLAUDE.md` is auto-loaded at session start, `.claude/hooks/*.sh` mechanically enforce the merge gate / ticket-first / secrets-scan rules, and `.claude/skills/*.md` become typed slash commands. [opencode](https://opencode.ai) has a different shape: a plugin-extensible agent CLI with a `tool.execute.before` lifecycle hook. It has no built-in slash-command runner and no Claude-Code-style hook wiring of its own. **apexyard reaches opencode through a plugin that shells out to the same, unmodified `.claude/hooks/*.sh` scripts Claude Code uses**: one governance implementation, enforced under two harnesses.

Decision record: [`AgDR-0092`](agdr/AgDR-0092-opencode-gate-adapter.md). Promoted from spike [me2resh/apexyard#816](https://github.com/me2resh/apexyard/issues/816) (verdict: VIABLE, proven fully live). Feature: me2resh/apexyard#821.

## What this enforces

The adapter (`harness-adapters/opencode/src/gate-dispatcher.ts`) does **not** hand-maintain a gate list. At plugin load, it reads the ops fork's `.claude/settings.json` and derives the full `PreToolUse` gate table from it. This includes every hook wired to the `Bash`, `Edit`, `Write`, `MultiEdit`, `Read`, `Glob`, or `Grep` matchers. It includes the multi-tracker merge-shape variants (`gh pr merge`, `gh api .../merge`, `glab mr merge`, `glab api`, `tracker_pr_merge`). This was originally a deliberate upgrade over the sibling pi adapter (`harness-adapters/pi/`), which shipped a hand-written, curated `DEFAULT_GATES` table. pi has since converged to the same settings.json-derived pattern (#840 C5). See `harness-adapters/_shared/derive-gates-core.ts`, the parsing core the two adapters now share. See `harness-adapters/opencode/src/derive-gates.ts` for the full rationale, referred to throughout this framework as "the #730 convergence". The design review on the Codex adapter, #730, first named the risk: a hand-maintained gate table can silently drift from `.claude/settings.json`.

Concretely, the opencode adapter enforces the following non-exhaustive list. The list is whatever `.claude/settings.json` wires, not a fixed set. It includes the two-marker merge gate (`block-unreviewed-merge.sh`) and red-CI merge blocking (`block-merge-on-red-ci.sh`). It includes design and architecture review gates (`require-design-review-for-ui.sh`, `require-architecture-review.sh`), secrets scanning (`check-secrets.sh`), and leak protection (`block-private-refs-in-public-repos.sh`). It includes ticket-first and migration-ticket-first edit blocking (`require-active-ticket.sh`, `require-migration-ticket.sh`), and every other blocking `PreToolUse` hook the framework ships or an adopter adds. This happens automatically, with zero adapter changes required when the framework or an adopter wires a new gate.

## Install

```bash
cd harness-adapters/opencode
npm install
cd ../..
bash bin/install-opencode-adapter.sh   # writes .opencode/plugins/apexyard/ in your CWD
```

**The discovery directory is PLURAL: `.opencode/plugins/`, not `.opencode/plugin/`.** An earlier version of this doc claimed opencode's discovery glob accepted either form. That was wrong, confirmed live against opencode 1.17.16 in [me2resh/apexyard#844](https://github.com/me2resh/apexyard/issues/844). The singular form silently loads nothing.

**Every adapter file must live inside one subdirectory, never flat in the discovery dir.** opencode's loader invokes EVERY exported function of a discovered file as a candidate plugin factory, not only its default export. `gate-dispatcher.ts` (the adapter's real implementation) exports several named helpers alongside its default plugin. With this file directly in `.opencode/plugins/`, opencode calls each helper as if it might be a plugin. This crashes the whole server at startup (`Error: {"name":"UnknownError","message":"Unexpected server error"}`; also #844, live). `bin/install-opencode-adapter.sh` avoids this by construction: it writes `.opencode/plugins/apexyard/index.ts`, a re-export shim whose ONLY export is the default plugin. It writes its helper modules as siblings inside that same subdirectory. opencode's subdirectory discovery only loads `index.ts` per subdir (verified live), so the helpers are never independently visited. See `harness-adapters/opencode/src/index.ts`'s header comment for the full mechanism, and `harness-adapters/opencode/README.md` for the script's `--target-dir`/`--root` options and the alternative `opencode.json` `plugin` config array install path.

## How it works

1. opencode calls the plugin once per session with `{directory, worktree, ...}`.
2. The plugin resolves the apexyard ops root. It walks up from `directory` for an `.apexyard-fork` marker or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair. Alternatively, it uses an explicit `APEXYARD_OPS_ROOT` override. It derives the gate table from that ops root's `.claude/settings.json`.
3. On every `tool.execute.before` event, the plugin checks the tool call against the derived gate table. A matching gate runs its bash hook as a real subprocess with the reconstructed Claude-Code-shaped stdin (`{tool_name, tool_input}`).
4. Exit code `2` → the plugin **throws**. This is opencode's only way to deny a tool call inside `tool.execute.before`. There is no `{block: true}` return the way pi has. Any other numeric exit code → allow. No numeric exit status at all → the plugin throws and **fails closed**. This covers spawn failure, output over the buffer ceiling, and signal kill. The plugin names the hook and the underlying error rather than silently letting the tool call through.

## Testing

```bash
cd harness-adapters/opencode
npm test               # hermetic unit tests: settings.json-derived gate matching,
                        # stdin construction, exit-2 -> throw mapping (subprocess exec mocked)
npm run typecheck      # verifies field-name assumptions against opencode's real, installed types
bash test/smoke-block-unreviewed-merge.sh   # real hook, real exec, fixture ops root, negative control
```

## What the proof covers, and what remains: the honest breakdown

| Claim | Status |
|-------|--------|
| opencode's real plugin API surface (`Plugin`, `PluginInput`, `Hooks["tool.execute.before"]`, the bash tool's registered id and `command` field, the edit/write tools' `filePath` field) | **Verified against the real, installed `@opencode-ai/plugin` package and opencode's own source** (`packages/opencode/src/tool/shell.ts`, `edit.ts`, `write.ts` in `sst/opencode`): not guessed from documentation alone. `npm run typecheck` re-verifies this on every run. |
| The gate table matches `.claude/settings.json`'s real wiring, including multi-tracker merge-shape globs | **Verified**: `derive-gates.test.ts` parses this repo's own real `.claude/settings.json` (not only a hand-written fixture). It asserts correct derivation of every named gate, plus the merge-gate's five glob variants. |
| A real, unmodified bash hook (`block-unreviewed-merge.sh`) blocks a fabricated merge command through the full dispatcher pipeline. The pipeline comprises settings.json parse → gate match → real subprocess exec → exit-code mapping | **Verified live**: `test/smoke-block-unreviewed-merge.sh` runs this against a fixture ops root with a real copy of `.claude/hooks/`. A negative control (no hook scripts present) proves the block is hook-driven, not unconditional. |
| A real, model-driven **opencode** agent turn invoking `tool.execute.before` with a matching event shape | **Proven once, live, by spike #816** (opencode ships a free no-API-key model, `opencode/big-pickle`). The unmodified `block-unreviewed-merge.sh` blocked a real model turn attempting `gh pr merge`. A negative control (corrupting the plugin) confirmed the block came from the plugin. **Not re-verified against this shipped, settings.json-derived dispatcher**: this build's environment had no opencode model credentials available to re-run that live check against the final code. The smoke script above re-proves everything downstream of opencode's own dispatch; the one hop it cannot re-prove is opencode's internal event-dispatch behavior itself. |
| The upstream `batch` tool bypass | **Not fixed, not ours to fix.** opencode's `batch` tool bypasses `Plugin.trigger()` entirely ([anomalyco/opencode#5894](https://github.com/anomalyco/opencode/issues/5894)): a batched tool call skips every plugin hook, including this dispatcher. Tracked here for visibility. |

### Closing the live-verification gap

Once opencode model credentials are available: load the plugin in a real opencode session pointed at an apexyard ops fork. Prompt a model turn that attempts an ungated `gh pr merge`. Confirm that the plugin refuses the tool call and surfaces `block-unreviewed-merge.sh`'s own reason text to the model. This repeats the same verification spike #816 already performed once against the throwaway prototype plugin. Re-run it here against the shipped, settings.json-derived dispatcher.

## Relationship to the pi and Codex adapters

| Adapter | Gate source | Mechanism |
|---------|-------------|-----------|
| `harness-adapters/pi/` | **Derived from `.claude/settings.json` per `tool_call` event** (AgDR-0082's "Update (GH-840)") | Dispatcher extension, `tool_call` event, `{block, reason}` return |
| `bin/sync-codex-adapter.sh` (Codex) | Generated from `.claude/settings.json` at build time (AgDR-0088) | Static `.codex/hooks.json`, predicates compiled into the generated command |
| `harness-adapters/opencode/` (this adapter) | **Derived from `.claude/settings.json` at plugin load time** | Dispatcher plugin, `tool.execute.before` event, throw-to-deny |

All three converge on the same underlying principle established by AgDR-0086 ("hooks stay bash, not ported"). `.claude/hooks/*.sh` remains the single source of truth for every gate decision. Every harness reaches it through a thin transport layer rather than a reimplementation. This adapter's contribution closes the "gate table can drift from settings.json" gap pi originally carried. pi now also includes this contribution (#840 C5), sharing the settings.json-parsing core (`harness-adapters/_shared/derive-gates-core.ts`) between the two. Each adapter keeps its own runtime-specific tool-vocabulary translation and `buildToolInput`.

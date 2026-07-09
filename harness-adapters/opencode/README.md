# apexyard opencode Gate Adapter

Enforces apexyard's mechanical governance gates inside [opencode](https://opencode.ai) (opencode.ai's agent CLI) by shelling out to the **existing, unmodified** bash hooks under `.claude/hooks/` — zero logic duplication. The bash hooks stay the single source of truth for every gate's approval decision; this package is a thin transport adapter between opencode's `tool.execute.before` event and each hook's stdin/exit-code contract.

Promoted from spike [me2resh/apexyard#816](https://github.com/me2resh/apexyard/issues/816) (verdict: VIABLE — **proven fully live**: a real, model-driven opencode turn attempting `gh pr merge` was blocked by the unmodified `block-unreviewed-merge.sh` via `tool.execute.before`, with a negative control — corrupting the plugin — proving the block came from the plugin, not opencode). See `docs/agdr/AgDR-0092-opencode-gate-adapter.md` for the design decision and `docs/opencode-adapter.md` for install + usage.

## What's different from the pi adapter

This adapter follows the same shape as `harness-adapters/pi/` (one dispatcher extension, real harness types, exit-2-maps-to-block) with one deliberate upgrade: **the gate table is derived from `.claude/settings.json` at plugin load time**, not hand-maintained. `src/derive-gates.ts` parses `.claude/settings.json`'s `PreToolUse` wiring directly — grouping the (sometimes multiple) rows that wire the same hook script into one `GateDefinition`, and preserving each row's Bash-command `if` glob. This is the convergence Tariq's review on #730 (the Codex adapter) asked for: the Codex adapter already generates its hook wiring from `.claude/settings.json` (`bin/sync-codex-adapter.sh`) rather than hand-copying it; this adapter applies the same principle without needing a static generation step, because opencode plugins are plain TypeScript that can read JSON at runtime — see `derive-gates.ts`'s header comment for the full rationale.

**Practical consequence**: every `PreToolUse` hook `.claude/settings.json` wires for `Bash`/`Edit`/`Write`/`MultiEdit`/`Read`/`Glob`/`Grep` is derived automatically, including hooks pi's hand-maintained `DEFAULT_GATES` table explicitly defers (`validate-branch-name.sh`, `validate-commit-format.sh`, `validate-pr-create.sh`, `require-skill-for-issue-create.sh`, and others — see `harness-adapters/pi/README.md` § "Known NOT-yet-bridged gates"). Advisory-only hooks (ones that never exit 2, e.g. `detect-role-trigger.sh`) are harmless to include — they run, they never throw, and a future hook added to `.claude/settings.json` is picked up with zero changes to this adapter. **The pi adapter is not modified by this package** — converging pi to the same derive-from-settings.json pattern is a follow-up, not part of this change.

## Install

```bash
cd harness-adapters/opencode
npm install       # pulls in @opencode-ai/plugin (real opencode types)
```

Then run the install script from your apexyard ops fork, from inside the project you want opencode to enforce gates in (or pass `--target-dir`):

```bash
bash <ops-fork>/bin/install-opencode-adapter.sh
```

This writes `.opencode/plugins/apexyard/` — **the discovery directory is PLURAL** (`.opencode/plugins/`, not `.opencode/plugin/`; an earlier version of this doc claimed opencode accepted either singular or plural, which was wrong — confirmed live against opencode 1.17.16 in [me2resh/apexyard#844](https://github.com/me2resh/apexyard/issues/844), the singular form silently loads nothing) — with `apexyard/index.ts` as the ONLY discovered file. Do not hand-copy `src/*.ts` flat into the discovery dir: opencode's loader invokes EVERY exported function of a discovered file as a candidate plugin factory, not only the default export, so `gate-dispatcher.ts`'s named helper exports (`execGateHookReal`, `buildToolExecuteBeforeHook`, `registerGateDispatcher`, …) get called directly and crash the whole server at startup if they sit in a scanned directory (also #844, live). `src/index.ts` is a re-export shim whose only export is the default plugin, and the install script places it — plus its helper modules as non-discovered siblings — inside one subdirectory. See `src/index.ts`'s header comment for the full mechanism.

```
Usage: bin/install-opencode-adapter.sh [--target-dir <path>] [--name <subdir>] [--root <path>]
```

`--target-dir` defaults to `<cwd>/.opencode/plugins` — run the script from the project being gated, or pass an explicit path. `--root` defaults to the script's own ops-fork root (where `harness-adapters/` lives) — pass it explicitly if you're invoking the script from outside that fork.

Or reference the real source file explicitly via opencode's `plugin` config array in `opencode.json`. This path is presumed unaffected by the directory-discovery bug above — the config array names one specific file rather than scanning a directory — but that presumption is NOT independently re-verified live for #844; if in doubt, prefer the install script's subdirectory-shim layout, which is:

```json
{
  "plugin": ["./harness-adapters/opencode/src/index.ts"]
}
```

## How it works

1. opencode calls the plugin's default export once per session, passing `{directory, worktree, client, project, $, ...}` (opencode's real `PluginInput` shape).
2. The plugin resolves the apexyard ops root (see "How ops-root resolution works" below) and, unless a custom gate table was passed, reads `.claude/settings.json` from that ops root and derives the full gate table from it.
3. It returns a `Hooks` object with a `"tool.execute.before"` handler. On every matching tool call, the handler:
   - Builds the exact Claude-Code-shaped stdin JSON (`{tool_name, tool_input}`) the target hook's own `jq` parsing expects.
   - Runs the hook as a real `bash <hook.sh>` subprocess with that JSON on stdin.
   - Maps the hook's exit code: `2` → **throw** (opencode's only way to deny a tool call inside `tool.execute.before` — there is no `{block: true}` return contract the way pi has), any other numeric exit code → allow, no numeric exit status at all (spawn failure, output over the buffer ceiling, signal kill) → **throw and fail CLOSED**, naming the hook and the underlying error.
4. The first gate that blocks wins — later gates for the same tool call are not evaluated, mirroring Claude Code's own `PreToolUse` semantics.

## How ops-root resolution works

Every gate hook needs to find the apexyard ops fork (where `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh` live) regardless of where opencode was launched from. This reuses the pi adapter's resolution approach (`harness-adapters/pi/src/resolve-ops-root.ts`) almost unchanged — see `src/resolve-ops-root.ts` for the full port — with one structural difference: **opencode resolves the ops root ONCE, at plugin init**, from the `directory`/`worktree` opencode's `PluginInput` provides, rather than per tool call the way the pi adapter does (pi hands the dispatcher a fresh `ctx.cwd` on every `tool_call` event; opencode's plugin function is called once per session and doesn't offer a fresher cwd afterward — see `resolve-ops-root.ts`'s header comment).

1. **Honors an explicit `APEXYARD_OPS_ROOT` environment variable** if set and valid — the same override name the pi adapter introduced, reused rather than inventing a second one.
2. **Falls back to a walk-up** from `directory`, looking for the same anchor apexyard's bash hooks recognise: a `.apexyard-fork` marker file, or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair.

If neither resolves, the dispatcher's `"tool.execute.before"` handler is a permanent no-op for the session — it fails toward **not enforcing**, never toward **false-blocking** a legitimate tool call it can't evaluate.

## Customizing the gate table

The gate table is derived automatically; you don't normally need to touch it. To override it entirely (e.g. to test a custom hook, or to pin a specific subset):

```ts
import { registerGateDispatcher, type GateDefinition } from "./src/gate-dispatcher.ts";

const myGates: GateDefinition[] = [
  {
    name: "my-custom-gate",
    hookRelativePath: ".claude/hooks/my-custom-gate.sh",
    wires: [{ tool: "bash", commandGlob: null }], // fires on every bash command
  },
];

export default async function myExtension(input) {
  return registerGateDispatcher(input, { gates: myGates });
}
```

## Testing

```bash
npm test           # hermetic unit tests — settings.json-derived gate matching,
                    # stdin construction, exit-2 -> throw mapping (exec MOCKED)
npm run typecheck  # tsc --noEmit against the real, installed @opencode-ai/plugin types

# + a smoke script proving a REAL hook (block-unreviewed-merge.sh) blocks a
# fabricated `gh pr merge` command through the real dispatcher pipeline in a
# fixture ops root, with a negative control proving the block is hook-driven:
bash test/smoke-block-unreviewed-merge.sh

# + a smoke script proving the REAL, SHIPPED install layout
# (bin/install-opencode-adapter.sh's output) loads cleanly in a fixture
# project: no top-level helper .ts files sit in the discovery dir, and
# apexyard/index.ts's module namespace is exactly ["default"], a working
# plugin factory (me2resh/apexyard#844):
bash test/smoke-install-layout.sh
```

`npm run typecheck` is what verifies this adapter's field-name assumptions (`input.tool === "bash"`, `output.args.command`, `output.args.filePath` for edit/write) against opencode's actual, installed `.d.ts` and its real tool source (`packages/opencode/src/tool/shell.ts`, `edit.ts`, `write.ts` in the `sst/opencode` repo) rather than documentation alone — the same discipline the pi adapter's own `npm run typecheck` note describes.

## Known gaps / what's unverified

- **(FIXED, #844) The documented install layout crashed a real opencode 1.17.16 session at startup.** The discovery dir was documented as singular (`.opencode/plugin/`) when the real, live-verified dir is plural (`.opencode/plugins/`); and a flat `cp src/*.ts` copy put `gate-dispatcher.ts`'s named helper exports and its sibling helper modules directly in the scanned directory, which opencode's loader tries to invoke as independent plugin factories — crashing the server before any gate could enforce anything. Fixed by shipping `src/index.ts` (a re-export shim exposing ONLY the default plugin) and `bin/install-opencode-adapter.sh` (which installs the shim plus its helper modules inside one non-discovered subdirectory, `.opencode/plugins/apexyard/`). See `src/index.ts`'s header comment and `test/smoke-install-layout.sh`.
- **A live, model-driven opencode agent turn triggering this exact shipped dispatcher.** Spike #816 proved the pattern viable with a real opencode session and a real model turn — but that proof was against the spike's throwaway prototype plugin, not this shipped, settings.json-derived dispatcher. This build's environment had no opencode model credentials available to re-run that live verification against the shipped code. `test/smoke-block-unreviewed-merge.sh` re-proves everything downstream of opencode's own event dispatch (stdin reconstruction, real hook exec, exit-code mapping) against the real, unmodified hook — the one hop it cannot re-prove is whether opencode's *internal* `tool.execute.before` dispatch calls this handler with a matching event shape during a live, model-driven turn. See `docs/opencode-adapter.md` for the exact steps to close this once credentials are available.
- **The upstream `batch` tool bypass** ([anomalyco/opencode#5894](https://github.com/anomalyco/opencode/issues/5894)): opencode's `batch` tool bypasses `Plugin.trigger()` entirely, so a batched tool call skips every plugin hook, including this dispatcher. This is an opencode-side gap, not something this adapter can close — tracked here for visibility, not owned by apexyard.
- **The `APEXYARD_OPS_ROOT` override has no equivalent to Claude Code's session-pin protection** against resolving to an unrelated ops-fork-shaped directory tree (apexyard#381) — identical limitation to the pi adapter, for the identical reason (no `CLAUDE_CODE_SESSION_ID` / SessionStart-hook equivalent in opencode).
- **Every derived gate hook still receives its input via a real subprocess spawn per matching tool call**, and — because the gate table is now the FULL wiring rather than a curated subset — more hooks run per bash call than the pi adapter's curated table would run. Each additional hook is a fast bash script (typically a handful of `jq`/`grep` calls), but this is a real, if small, per-call latency trade-off for the "can't drift from settings.json" property. Not measured/benchmarked in this build.
- **Gate execution failures fail CLOSED, not open** — mirrors the pi adapter's fix for a Rex finding on PR #817: if a hook can't produce a numeric exit status at all, the dispatcher throws with a reason naming the hook and the underlying error, rather than silently allowing the tool call through. See `src/gate-dispatcher.ts`'s `runGateHook` doc comment and the "FAILS CLOSED" test in `test/gate-dispatcher.test.ts`.

## Glossary

| Term | Definition |
|------|------------|
| opencode | opencode.ai — an open-source AI coding harness with a `tool.execute.before` plugin hook |
| adapter-over-bash | A thin per-harness extension that invokes apexyard's existing bash gate hooks rather than reimplementing the gate logic natively |
| `tool.execute.before` | opencode's pre-execution lifecycle event; a plugin's handler can deny a tool call by throwing before it runs |
| ops root | The apexyard fork's root directory, where `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh` live |
| dispatcher | A single plugin that checks a tool call against a table of gate definitions derived from `.claude/settings.json`, rather than one plugin per gate |
| derive-from-settings.json | Building the gate table by parsing `.claude/settings.json` at runtime instead of hand-maintaining a parallel table — the #730 convergence this adapter implements |
| proven live | Observed directly against the real running system (real bash hook, real opencode session) |
| proven by construction | Demonstrated via a mock built to match the documented/typed contract, not observed inside a live opencode agent turn |

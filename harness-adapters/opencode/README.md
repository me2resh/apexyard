# apexyard opencode Gate Adapter

Enforces apexyard's mechanical governance gates inside [opencode](https://opencode.ai) (opencode.ai's agent CLI) by shelling out to the **existing, unmodified** bash hooks under `.claude/hooks/`. Zero logic duplication. The bash hooks stay the single source of truth for every gate's approval decision. This package is a thin transport adapter between opencode's `execute.before` tool hook and each hook's stdin/exit-code contract.

**Targets opencode 2.x (V2 plugin API).** V1 plugins — a default-exported `async (input) => hooks` factory — are rejected by opencode 2.x with `Plugin must export a default definition with an id and an effect or setup function`. This adapter default-exports `{ id: "apexyard.gates", setup }` and registers its hook through `ctx.tool.hook("execute.before", …)`. See "Migrating from V1" below.

Promoted from spike [me2resh/apexyard#816](https://github.com/me2resh/apexyard/issues/816) (verdict: VIABLE — **proven fully live**: a real, model-driven opencode turn attempting `gh pr merge` was blocked by the unmodified `block-unreviewed-merge.sh` via opencode's pre-execution tool hook, with a negative control — corrupting the plugin — proving the block came from the plugin, not opencode). See `docs/agdr/AgDR-0092-opencode-gate-adapter.md` for the design decision and `docs/opencode-adapter.md` for install + usage.

## What's different from the pi adapter

This adapter follows the same shape as `harness-adapters/pi/` (one dispatcher extension, real harness types, exit-2-maps-to-block) with one deliberate upgrade: **the gate table is derived from `.claude/settings.json` at plugin load time**, not hand-maintained. `src/derive-gates.ts` parses `.claude/settings.json`'s `PreToolUse` wiring directly — grouping the (sometimes multiple) rows that wire the same hook script into one `GateDefinition`, and preserving each row's Bash-command `if` glob. This is the convergence Tariq's review on #730 (the Codex adapter) asked for: the Codex adapter already generates its hook wiring from `.claude/settings.json` (`bin/sync-codex-adapter.sh`) rather than hand-copying it; this adapter applies the same principle without needing a static generation step, because opencode plugins are plain TypeScript that can read JSON at runtime — see `derive-gates.ts`'s header comment for the full rationale.

**Practical consequence**: every `PreToolUse` hook `.claude/settings.json` wires for `Bash`/`Edit`/`Write`/`MultiEdit`/`Read`/`Glob`/`Grep` is derived automatically, including hooks pi's hand-maintained `DEFAULT_GATES` table explicitly defers (`validate-branch-name.sh`, `validate-commit-format.sh`, `validate-pr-create.sh`, `require-skill-for-issue-create.sh`, and others — see `harness-adapters/pi/README.md` § "Known NOT-yet-bridged gates"). Advisory-only hooks (ones that never exit 2, e.g. `detect-role-trigger.sh`) are harmless to include — they run, they never throw, and a future hook added to `.claude/settings.json` is picked up with zero changes to this adapter. **The pi adapter is not modified by this package** — converging pi to the same derive-from-settings.json pattern is a follow-up, not part of this change.

## Install

```bash
cd harness-adapters/opencode
npm install       # pulls in @opencode/plugin (real opencode 2.x plugin types)
```

Then run the install script from your apexyard ops fork, from inside the project you want opencode to enforce gates in (or pass `--target-dir`):

```bash
bash <ops-fork>/bin/install-opencode-adapter.sh
```

This writes `.opencode/plugins/apexyard/` — **the discovery directory is PLURAL** (`.opencode/plugins/`, not `.opencode/plugin/`; an earlier version of this doc claimed opencode accepted either singular or plural, which was wrong — confirmed live against opencode 1.17.16 in [me2resh/apexyard#844](https://github.com/me2resh/apexyard/issues/844), the singular form silently loads nothing) — with `apexyard/index.ts` as the ONLY discovered file. Do not hand-copy `src/*.ts` flat into the discovery dir: on V1 opencode's loader invoked EVERY exported function of a discovered file as a candidate plugin factory, not only the default export, so `gate-dispatcher.ts`'s named helper exports (`execGateHookReal`, `buildToolExecuteBeforeHandler`, `registerGateDispatcher`, …) got called directly and crashed the whole server at startup if they sat in a scanned directory (also #844, live). V2 validates only the `default` export, so that specific crash is gone — the shim is kept anyway so "the discovered module exports exactly `default`" stays a structural invariant rather than a loader-version accident. `src/index.ts` is a re-export shim whose only export is the default plugin definition, and the install script places it — plus its helper modules as non-discovered siblings — inside one subdirectory. See `src/index.ts`'s header comment for the full mechanism.

```
Usage: bin/install-opencode-adapter.sh [--target-dir <path>] [--name <subdir>] [--root <path>]
```

`--target-dir` defaults to `<cwd>/.opencode/plugins` — run the script from the project being gated, or pass an explicit path. `--root` defaults to the script's own ops-fork root (where `harness-adapters/` lives) — pass it explicitly if you're invoking the script from outside that fork.

Or reference the adapter directory explicitly via opencode's `plugins` array in `opencode.json` (V2 name; V1 called the key `plugin`). In V2 a configured local path must be a **directory** — a path to a single file is skipped with a log warning — so point it at a directory containing `index.ts`:

```json
{
  "plugins": ["./harness-adapters/opencode/src"]
}
```

That directory holds `index.ts` plus its sibling modules, which is the shape V2's local-plugin resolution expects (`server`, else `index`). This config path is not independently re-verified live; if in doubt, prefer the install script's subdirectory layout.

## How it works

1. opencode loads the default export — a V2 definition object `{ id, setup }` — and calls `setup(ctx)` once per plugin instance, passing opencode's V2 plugin `Context` (the server client plus `location`, `options`, and the domain APIs).
2. `setup` resolves the apexyard ops root from `ctx.location.directory` (see "How ops-root resolution works" below) and, unless a custom gate table was passed, reads `.claude/settings.json` from that ops root and derives the full gate table from it.
3. It registers one hook — `ctx.tool.hook("execute.before", handler)`. On every matching tool call, the handler:
   - Builds the exact Claude-Code-shaped stdin JSON (`{tool_name, tool_input}`) the target hook's own `jq` parsing expects.
   - Runs the hook as a real `bash <hook.sh>` subprocess with that JSON on stdin.
   - Maps the hook's exit code: `2` → **throw** (throwing inside the hook is opencode's way to deny a tool call — there is no `{block: true}` return contract the way pi has), any other numeric exit code → allow, no numeric exit status at all (spawn failure, output over the buffer ceiling, signal kill) → **throw and fail CLOSED**, naming the hook and the underlying error.
4. The first gate that blocks wins — later gates for the same tool call are not evaluated, mirroring Claude Code's own `PreToolUse` semantics.

## How ops-root resolution works

Every gate hook needs to find the apexyard ops fork (where `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh` live) regardless of where opencode was launched from. This reuses the pi adapter's resolution approach (`harness-adapters/pi/src/resolve-ops-root.ts`) almost unchanged — see `src/resolve-ops-root.ts` for the full port — with one structural difference: **opencode resolves the ops root ONCE, at plugin setup**, from `ctx.location.directory`, rather than per tool call the way the pi adapter does (pi hands the dispatcher a fresh `ctx.cwd` on every `tool_call` event; a V2 opencode hook event carries no working directory, and `ctx.location` describes where the plugin instance loaded — see `resolve-ops-root.ts`'s header comment).

1. **Honors an explicit `APEXYARD_OPS_ROOT` environment variable** if set and valid — the same override name the pi adapter introduced, reused rather than inventing a second one.
2. **Falls back to a walk-up** from `ctx.location.directory`, looking for the same anchor apexyard's bash hooks recognise: a `.apexyard-fork` marker file, or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair.

If neither resolves, the registered `execute.before` hook is a permanent no-op for the plugin instance — it fails toward **not enforcing**, never toward **false-blocking** a legitimate tool call it can't evaluate.

## Customizing the gate table

The gate table is derived automatically; you don't normally need to touch it. To override it entirely (e.g. to test a custom hook, or to pin a specific subset):

```ts
import { registerGateDispatcher, type GateDefinition } from "./src/gate-dispatcher.ts";

const myGates: GateDefinition[] = [
  {
    name: "my-custom-gate",
    hookRelativePath: ".claude/hooks/my-custom-gate.sh",
    wires: [{ tool: "shell", commandGlob: null }], // fires on every shell command
  },
];

export default {
  id: "my.extension",
  setup: (ctx) => registerGateDispatcher(ctx, { gates: myGates }),
};
```

`wires[].tool` is the opencode tool id the gate matches: `shell` (V2) / `bash` (V1), `edit`, `write`, `read`, `glob`, `grep`. The Bash matcher in `.claude/settings.json` is translated to **both** `shell` and `bash` so a gate cannot silently stop matching across opencode generations.

## Testing

```bash
npm test           # hermetic unit tests — settings.json-derived gate matching,
                    # stdin construction, exit-2 -> throw mapping (exec MOCKED)
npm run typecheck  # tsc --noEmit against the real, installed @opencode/plugin types

# + a smoke script proving a REAL hook (block-unreviewed-merge.sh) blocks a
# fabricated `gh pr merge` command through the real V2 dispatcher pipeline in
# a fixture ops root, with a negative control proving the block is hook-driven:
bash test/smoke-block-unreviewed-merge.sh

# + a smoke script proving the REAL, SHIPPED install layout
# (bin/install-opencode-adapter.sh's output) loads cleanly in a fixture
# project: no top-level helper .ts files sit in the discovery dir,
# apexyard/index.ts's module namespace is exactly ["default"], its default
# export is a V2 `{ id, setup }` definition, and setup() registers an
# execute.before hook (me2resh/apexyard#844 + the V2 port):
bash test/smoke-install-layout.sh
```

`npm run typecheck` is what verifies this adapter's field-name assumptions (`event.tool === "shell"` on V2 / `"bash"` on V1, `event.input.command`, and `event.input.path` for edit/write — the V1 name was `filePath`) against opencode's installed `@opencode/plugin` `.d.ts` and the V2 tools documentation rather than guesswork — the same discipline the pi adapter's own `npm run typecheck` note describes.

## Migrating from V1

opencode 2.x rejects a V1 plugin outright, with a WARN in the server log and a `failed` status in the plugin list:

```
level=WARN message="failed to load plugin"
cause="PluginModule.LoadError: Plugin must export a default definition with an id
and an effect or setup function. (cause: SchemaError(Expected object at [\"default\"]))"
```

The cause is structural, not configuration: V1 plugins default-export a **function** (`async (input) => hooks`), and V2 validates the default export as an **object** carrying `id` plus `setup` (or `effect`). Moving the file or renaming a config key does not help — the implementation has to be ported. Adapter `0.2.0` does that port:

| Concern | V1 (0.1.x) | V2 (0.2.0) |
|---------|------------|------------|
| Default export | `async (input) => hooks` | `{ id: "apexyard.gates", setup(ctx) }` |
| Types package | `@opencode-ai/plugin` | `@opencode/plugin` |
| Init input | `{ directory, worktree, … }` (`PluginInput`) | `ctx.location.directory` (plugin `Context`) |
| Hook registration | returned `{ "tool.execute.before": fn }` | `ctx.tool.hook("execute.before", fn)` |
| Hook arguments | `(input, output)` — `output.args` | one event: `{ tool, input }` |
| Command tool id | `bash` | `shell` |
| edit/write file arg | `filePath` | `path` |
| Denying a call | throw | throw (unchanged) |

The adapter accepts **both** vocabularies (`shell`/`bash`, `path`/`filePath`) so the same build cannot silently stop matching gates on either generation — a wrong tool id fails open with no error anywhere, which is the worst possible failure mode for a governance plugin. `test/smoke-install-layout.sh` now asserts the V2 shape (`id` + `setup` + a registered `execute.before`), so this regression cannot return unnoticed.

If you must stay on opencode 1.x, pin adapter `0.1.0`.

## Known gaps / what's unverified

- **(FIXED, #844) The documented install layout crashed a real opencode 1.17.16 session at startup.** The discovery dir was documented as singular (`.opencode/plugin/`) when the real, live-verified dir is plural (`.opencode/plugins/`); and a flat `cp src/*.ts` copy put `gate-dispatcher.ts`'s named helper exports and its sibling helper modules directly in the scanned directory, which opencode's loader tries to invoke as independent plugin factories — crashing the server before any gate could enforce anything. Fixed by shipping `src/index.ts` (a re-export shim exposing ONLY the default plugin) and `bin/install-opencode-adapter.sh` (which installs the shim plus its helper modules inside one non-discovered subdirectory, `.opencode/plugins/apexyard/`). See `src/index.ts`'s header comment and `test/smoke-install-layout.sh`.
- **(CLOSED, 2026-11-04) A live, model-driven opencode agent turn triggering this exact shipped dispatcher.** Spike #816 proved the pattern under V1 with the throwaway prototype. Under V2, the ported adapter was verified live on opencode 2.1.4: a real agent session — plugin installed at `.opencode/plugins/apexyard/`, no test harness — issued `gh pr merge 999999 --repo <nonexistent-fixture> --squash` through the `shell` tool and was refused with `block-unreviewed-merge.sh`'s own reason text. That proves the loader accepts the V2 definition, `setup` registers `execute.before`, and opencode dispatches a real `shell` call carrying `event.input.command` into the handler.
- **(V2 PORT, adapter 0.2.0) The adapter is V2-only at the entrypoint.** opencode 1.x is no longer supported by this build; pin `0.1.0` if you need it. The internal gate logic, hook-stdin contract, and exit-code mapping are unchanged. The port's riskiest assumption was the tool vocabulary: V2 renamed the command tool `bash` → `shell` and the edit/write file argument `filePath` → `path`. Both vocabularies are accepted, because getting that wrong fails **open** — gates would simply never match, with no error anywhere — which is the worst failure mode for a governance plugin. `test/smoke-install-layout.sh` asserts the V2 definition shape and that `setup` registers `execute.before`.
- **The upstream `batch` tool bypass** ([anomalyco/opencode#5894](https://github.com/anomalyco/opencode/issues/5894)): opencode's `batch` tool bypasses `Plugin.trigger()` entirely, so a batched tool call skips every plugin hook, including this dispatcher. This is an opencode-side gap, not something this adapter can close — tracked here for visibility, not owned by apexyard.
- **The `APEXYARD_OPS_ROOT` override has no equivalent to Claude Code's session-pin protection** against resolving to an unrelated ops-fork-shaped directory tree (apexyard#381) — identical limitation to the pi adapter, for the identical reason (no `CLAUDE_CODE_SESSION_ID` / SessionStart-hook equivalent in opencode).
- **Every derived gate hook still receives its input via a real subprocess spawn per matching tool call**, and — because the gate table is now the FULL wiring rather than a curated subset — more hooks run per bash call than the pi adapter's curated table would run. Each additional hook is a fast bash script (typically a handful of `jq`/`grep` calls), but this is a real, if small, per-call latency trade-off for the "can't drift from settings.json" property. Not measured/benchmarked in this build.
- **Gate execution failures fail CLOSED, not open** — mirrors the pi adapter's fix for a Rex finding on PR #817: if a hook can't produce a numeric exit status at all, the dispatcher throws with a reason naming the hook and the underlying error, rather than silently allowing the tool call through. See `src/gate-dispatcher.ts`'s `runGateHook` doc comment and the "FAILS CLOSED" test in `test/gate-dispatcher.test.ts`.

## Glossary

| Term | Definition |
|------|------------|
| opencode | opencode.ai — an open-source AI coding harness with a `execute.before` tool hook (V1 called it `tool.execute.before`) |
| adapter-over-bash | A thin per-harness extension that invokes apexyard's existing bash gate hooks rather than reimplementing the gate logic natively |
| `execute.before` | opencode V2's pre-execution tool hook, registered with `ctx.tool.hook("execute.before", …)`; a plugin's handler denies a tool call by throwing before it runs. V1 exposed the same lifecycle as a returned `"tool.execute.before"` entry |
| plugin definition | opencode V2's required default export shape — `{ id, setup }` (or `{ id, effect }`). A bare function is a V1 plugin and is rejected by 2.x |
| ops root | The apexyard fork's root directory, where `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh` live |
| dispatcher | A single plugin that checks a tool call against a table of gate definitions derived from `.claude/settings.json`, rather than one plugin per gate |
| derive-from-settings.json | Building the gate table by parsing `.claude/settings.json` at runtime instead of hand-maintaining a parallel table — the #730 convergence this adapter implements |
| proven live | Observed directly against the real running system (real bash hook, real opencode session) |
| proven by construction | Demonstrated via a mock built to match the documented/typed contract, not observed inside a live opencode agent turn |

# apexyard pi Gate Adapter

Enforces apexyard's mechanical governance gates inside [pi](https://pi.dev) (Earendil's agent CLI) by shelling out to the **existing, unmodified** bash hooks under `.claude/hooks/` — zero logic duplication. The bash hooks stay the single source of truth for every gate's approval decision; this package is a thin transport adapter between pi's `tool_call` event and each hook's stdin/exit-code contract.

Promoted from spike [me2resh/apexyard#804](https://github.com/me2resh/apexyard/issues/804) (verdict: VIABLE). See `docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md` for the design decision and `docs/spike-reports/pi-gate-extension.md` for the spike's own findings.

## What this enforces

**(#840 C5 update)** The dispatcher (`src/gate-dispatcher.ts`) no longer hand-maintains a curated gate list — it derives the FULL gate table from `.claude/settings.json` at the moment of each `tool_call` event, via `src/derive-gates.ts`. Every `PreToolUse` hook wired for the `Bash`/`Edit`/`Write`/`MultiEdit`/`Read`/`Glob`/`Grep` matchers is picked up automatically (`Glob` maps onto pi's `find` tool — pi has no separate `glob` tool; `MultiEdit` collapses onto `edit`, same as opencode's adapter), with zero adapter changes required when a new gate is wired. This converges pi to the exact pattern the opencode adapter established (AgDR-0092), closing the drift risk Tariq's #730 review named and this package's own README used to describe as a "curated subset, not the full list."

Gates wired to `read`/`grep`/`find`/`ls` (today: `suggest-mcp-search.sh`, an advisory-only hook) are derived but **cannot be evaluated** — this adapter has no verified pi stdin shape for those tool types and deliberately does not guess one (see `derive-gates.ts`'s header comment). The dispatcher warns once to stderr, per (ops root, gate, tool), when this happens — see "Known gaps / what's unverified" below.

See `docs/agdr/AgDR-0082-pi-gate-dispatcher-adapter.md`'s "Update (GH-840)" section for the full decision record.

## Install

```bash
cd harness-adapters/pi
npm install       # pulls in @earendil-works/pi-coding-agent (real pi types + runtime)
```

Then load the extension in a pi session pointed at your apexyard ops fork:

```bash
pi --extension harness-adapters/pi/src/gate-dispatcher.ts
```

Or install it as a project-local extension pi auto-discovers, via the install script rather than a hand-copy dance:

```bash
bash <ops-fork>/bin/install-pi-adapter.sh
```

```
Usage: bin/install-pi-adapter.sh [--target-dir <path>] [--name <subdir>] [--root <path>]
```

`--target-dir` defaults to `<cwd>/.pi/extensions` — run the script from the project you want pi to enforce gates in, or pass an explicit path. `--root` defaults to the script's own ops-fork root (where `harness-adapters/` lives).

**Do not hand-copy `gate-dispatcher.ts` and `resolve-ops-root.ts` flat into `.pi/extensions/`** — that was the documented install before [me2resh/apexyard#844](https://github.com/me2resh/apexyard/issues/844), and it crashes a real pi session: pi's discovery scans every top-level `.ts` file under `.pi/extensions/` and requires each one to export a valid default factory function. `resolve-ops-root.ts` (and, since #840 C5, `derive-gates.ts`) have no default export at all — pi fails the whole session with `Error: Failed to load extension ".../resolve-ops-root.ts": Extension does not export a valid factory function`, confirmed live against pi 0.80.3. The install script avoids this by construction: every file the adapter needs lives inside ONE subdirectory (`.pi/extensions/apexyard/` by default), with `index.ts` as pi's only discovered entry per subdirectory — the helper files sit there as ordinary relative imports pi's discovery scan never independently visits. See `src/index.ts`'s header comment for the full mechanism.

(pi loads extensions via `jiti` with no compile step — plain `.ts`, no build pipeline, matching the bash hooks' own "just a script" simplicity.)

## How ops-root resolution works

Every gate hook needs to find the apexyard ops fork (where `.claude/session/reviews/*.approved` markers live) regardless of pi's current working directory. Claude Code resolves this via `_lib-ops-root.sh`, which layers a SessionStart-written pin on top of a directory walk-up. pi has no session-pin equivalent, so this adapter:

1. **Honors an explicit `APEXYARD_OPS_ROOT` environment variable** if set and valid (recommended when running pi from a directory that isn't the ops fork's own working tree — e.g. a project workspace clone).
2. **Falls back to a walk-up** from `ctx.cwd`, looking for the same anchor apexyard's bash hooks recognise: a `.apexyard-fork` marker file, or the legacy `onboarding.yaml` + `apexyard.projects.yaml` pair.

If neither resolves, the dispatcher is a silent no-op for that tool call — it fails toward **not enforcing**, never toward **false-blocking** a legitimate tool call it can't evaluate.

See `src/resolve-ops-root.ts` and AgDR-0082 for the full rationale, including the one safety property Claude Code's session pin provides that this adapter does NOT (protection against a pi session accidentally resolving to an unrelated ops-fork-shaped directory tree, e.g. a throwaway clone).

## Customizing the gate table

By default `registerGateDispatcher` derives the gate table from `.claude/settings.json` on every `tool_call` — pass an explicit `gates` array to override that entirely (e.g. to pin a fixed subset, or to add a gate this framework doesn't wire in `settings.json`):

```ts
import { registerGateDispatcher, deriveGatesFromOpsRoot, type GateDefinition } from "./src/gate-dispatcher.ts";

const myGates: GateDefinition[] = [
  ...deriveGatesFromOpsRoot(process.env.APEXYARD_OPS_ROOT!, ".claude/settings.json"),
  {
    name: "my-custom-gate",
    hookRelativePath: ".claude/hooks/my-custom-gate.sh",
    wires: [{ tool: "bash", commandGlob: null }],
  },
];

export default function myExtension(pi) {
  registerGateDispatcher(pi, { gates: myGates });
}
```

## Testing

```bash
# hermetic — isolated fixture ops roots, no gh calls, no real pi package needed
node --test test/*.test.ts

# + LIVE cases against this repo's real block-unreviewed-merge.sh and real gh state
APEXYARD_TEST_REPO_ROOT="$(pwd)/.." ALLOW_TEST_PR=<pr-with-real-rex+ceo-markers> node --test test/gate-dispatcher.test.ts

# + a smoke script proving the REAL, SHIPPED install layout
# (bin/install-pi-adapter.sh's output) loads cleanly in a fixture project:
# no top-level helper .ts files sit in the discovery dir, and
# apexyard/index.ts's module namespace is exactly ["default"], a working
# extension factory (me2resh/apexyard#844):
bash test/smoke-install-layout.sh
```

`test/derive-gates.test.ts` covers the settings.json-parsing/translation layer in isolation (mirrors `harness-adapters/opencode/test/derive-gates.test.ts`); `test/gate-dispatcher.test.ts` covers dispatch + exec + the LIVE cases above.

`npm run typecheck` runs `tsc --noEmit` against the real `@earendil-works/pi-coding-agent` types — this is what verifies the adapter's field-name assumptions (e.g. `event.input.path` for edit/write, `event.input.command` for bash) against pi's actual, installed `.d.ts` rather than against documentation alone.

## Known gaps / what's unverified

This build (me2resh/apexyard#815) closed most of the gaps the spike flagged, but one remains — and it's the one that matters most for a production merge gate:

- **(FIXED, #844) The documented install layout crashed a real pi 0.80.3 session at startup.** `resolve-ops-root.ts` (and, since #840 C5, `derive-gates.ts`) have no default export; copied flat alongside `gate-dispatcher.ts` into `.pi/extensions/`, pi's discovery tried to load them as independent extensions and aborted the whole session before any gate could enforce anything. Fixed by shipping `src/index.ts` (the sole default-exporting entry point `bin/install-pi-adapter.sh` installs into a dedicated, non-flat subdirectory alongside its non-discovered helper siblings). See `src/index.ts`'s header comment and `test/smoke-install-layout.sh`.
- **Verified against pi's real, installed `.d.ts`**: the exact shape of `ToolCallEvent`, `ToolCallEventResult`, `ExtensionAPI`, and the edit/write tools' `path` field name (not `file_path`) — this is now typechecked (`npm run typecheck`), not guessed.
- **Verified live, against the real bash hook + real GitHub state**: the full stdin-reconstruction → hook-exec → exit-code-mapping path, using a synthetic `tool_call` event that mocks only pi's `ExtensionAPI.on()` registration call (see `test/gate-dispatcher.test.ts`'s "LIVE" cases, run against real PR #767's real Rex+CEO markers and a real nonexistent-PR block).
- **NOT verified** (and could not be verified in the environment this was built in — no pi model credentials available): that a real, model-driven pi agent turn actually invokes `tool_call` handlers with events matching this contract when the model itself calls the `bash`/`edit`/`write` tools. This is a transport-fidelity assumption inherited from spike #804's own "proven by construction, not proven live" finding for the same reason — it needs a live model API key this environment doesn't have. Once available, the correct test is: run a real pi session with this extension loaded, prompt a model turn that attempts an ungated `gh pr merge`, and confirm the tool call is refused with the hook's block reason surfaced to the model.
- **The pi-flavored ops-root override (`APEXYARD_OPS_ROOT`) has no equivalent to Claude Code's session-pin protection** against resolving to an unrelated ops-fork-shaped directory tree (see "How ops-root resolution works" above and AgDR-0082).
- **`check-secrets.sh` scans `git diff --cached` relative to `cwd: opsRoot`, with no additional cd-resolution.** If a pi session is launched from inside a nested or otherwise different git repo than the intended one, the secrets scan runs against the *ops fork's* staged diff, not the repo the operator actually meant to scan. This mirrors an equivalent limitation Claude Code already has (the hook resolves the same way there), so it's not a regression introduced by this adapter — noted here for completeness, no code change made.
- **Gate execution failures fail CLOSED, not open** (fixed after a Rex finding on PR #817, extended to cover a bounded timeout in #840 C1): if a hook can't produce a numeric exit status at all — a spawn failure, output exceeding the 10 MB `maxBuffer` ceiling, a signal kill, or exceeding the 30s exec timeout — the dispatcher BLOCKS with a reason naming the hook and the underlying error, rather than silently allowing the tool call through. Only a genuine hook exit code of 0 (or a numeric non-2 exit code) allows the call; exit code 2 blocks with the hook's own reason. See `src/gate-dispatcher.ts`'s `runGateHook` doc comment for the full semantics and `test/gate-dispatcher.test.ts`'s "FAILS CLOSED" tests.
- **Gates wired to `read`/`grep`/`find`/`ls` cannot be evaluated** (#840 C5): this adapter has no verified pi stdin shape for those tool types (see `derive-gates.ts`'s header comment for why it doesn't guess one). The dispatcher warns once to stderr, per (ops root, gate, tool), naming exactly which gate is silently un-enforceable for which tool — see `findUnsupportedGateWires` and `test/gate-dispatcher.test.ts`'s dedup test.
- **The derived gate table is re-parsed from `.claude/settings.json` on every `tool_call` event, not cached** (#840 C5): correct for live edits to `.claude/settings.json` mid-session, at the cost of one extra JSON parse per call — negligible next to the subprocess spawn(s) that follow. See `src/gate-dispatcher.ts`'s header comment for the full rationale (pi hands a fresh `ctx.cwd` per event, unlike opencode's once-at-init lifecycle).

## Glossary

| Term | Definition |
|------|------------|
| pi | pi.dev — Earendil's minimal, unopinionated agent CLI with a TypeScript extension system |
| adapter-over-bash | A thin per-harness extension that invokes apexyard's existing bash gate hooks rather than reimplementing the gate logic natively |
| `tool_call` event | pi's pre-execution lifecycle event; extensions registered via `pi.on("tool_call", handler)` can block or allow a tool invocation before it runs |
| ops root | The apexyard fork's root directory, where `.claude/session/reviews/*.approved` markers and `.claude/hooks/*.sh` live |
| dispatcher | A single extension that checks a tool call against a table of gate definitions, rather than one extension per gate |
| proven live | Observed directly against the real running system (real bash hook, real `gh` calls) |
| proven by construction | Demonstrated via a mock built to match the documented/typed contract, not observed inside a live pi agent turn |

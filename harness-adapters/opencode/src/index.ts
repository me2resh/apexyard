/**
 * index.ts — the ONE file opencode's `.opencode/plugins/<subdir>/`
 * auto-discovery loads out of an installed adapter subdirectory
 * (me2resh/apexyard#844).
 *
 * THE BUG THIS FILE FIXES
 * -------------------------
 * Two independent problems, both confirmed live against opencode 1.17.16:
 *
 *   1. The documented discovery directory was singular (`.opencode/plugin/`)
 *      — the real, live-verified discovery dir is PLURAL,
 *      `.opencode/plugins/`. The singular form silently loads nothing.
 *   2. opencode's loader treats EVERY exported function of a discovered
 *      file as a candidate plugin factory, not only its default export —
 *      it calls each one and awaits the result. `gate-dispatcher.ts` (this
 *      adapter's actual implementation) exports several named helper
 *      functions alongside its default (`execGateHookReal`,
 *      `buildToolExecuteBeforeHook`, `registerGateDispatcher`, …). Placed
 *      directly in the discovery dir, opencode calls e.g.
 *      `execGateHookReal(pluginInput)` as if it might be a plugin factory —
 *      it isn't one, it's a positional-args helper — and it throws
 *      (`execFileSync` receiving a `PluginInput` object where it expected a
 *      string path), crashing the whole opencode server at startup:
 *      `Error: {"name":"UnknownError","message":"Unexpected server error"}`.
 *      Copying the SIBLING helper files (`derive-gates.ts`,
 *      `resolve-ops-root.ts`) into the same directory makes opencode try to
 *      load THEM as plugins too, independent of problem 2 above.
 *
 * THE FIX IS INSTALL LAYOUT, NOT DISPATCH LOGIC
 * -------------------------------------------------
 * This file is a re-export shim whose ONLY export is the default plugin —
 * `export { default } from "./gate-dispatcher.ts"` re-exports NOTHING but
 * gate-dispatcher.ts's default export; none of its named helper functions
 * leak through. `Object.keys(await import("./index.ts"))` is
 * `["default"]`. This is the single file opencode's plugin-subdirectory
 * discovery is meant to see.
 *
 * Every file this adapter needs (this shim, `gate-dispatcher.ts`,
 * `derive-gates.ts`, `resolve-ops-root.ts`, and a sibling copy of the
 * shared `derive-gates-core.ts`) ships inside ONE subdirectory —
 * `.opencode/plugins/apexyard/` by convention, produced by
 * `bin/install-opencode-adapter.sh` rather than a hand-copy dance. Only
 * `.opencode/plugins/apexyard/index.ts` is discovered (verified live
 * against opencode 1.17.16 — see #844); the sibling helper files sit there
 * as ordinary relative imports the discovery scan never independently
 * visits, so their multiple named exports are never a problem.
 *
 * See `harness-adapters/pi/src/index.ts`'s header comment for why pi ships
 * the identical shim shape even though pi's own loader only inspects the
 * `default` export (this ticket's "same fix shape" instruction) — a shim
 * is a no-op-safe superset there and load-bearing here.
 */

export { default } from "./gate-dispatcher.ts";

/**
 * index.ts — the ONE file opencode's `.opencode/plugins/<subdir>/`
 * auto-discovery loads out of an installed adapter subdirectory.
 *
 * WHY A SHIM INSTEAD OF POINTING AT gate-dispatcher.ts DIRECTLY
 * ---------------------------------------------------------------
 * Two independent problems, both originally confirmed live against opencode
 * 1.17.16 (me2resh/apexyard#844):
 *
 *   1. The documented discovery directory was singular (`.opencode/plugin/`)
 *      — the real discovery dir is PLURAL, `.opencode/plugins/`. The singular
 *      form silently loads nothing. (V2 accepts both, but plural is the
 *      documented V2 layout.)
 *   2. V1's loader treated EVERY exported function of a discovered file as a
 *      candidate plugin factory, not only its default export — it called each
 *      one and awaited the result. `gate-dispatcher.ts` (this adapter's actual
 *      implementation) exports several named helper functions alongside its
 *      default (`execGateHookReal`, `buildToolExecuteBeforeHandler`,
 *      `registerGateDispatcher`, …). Placed directly in the discovery dir,
 *      opencode called e.g. `execGateHookReal(pluginInput)` as if it might be
 *      a plugin factory — it isn't one, it's a positional-args helper — and it
 *      threw, crashing the whole opencode server at startup. Copying the
 *      SIBLING helper files (`derive-gates.ts`, `resolve-ops-root.ts`) into
 *      the same directory made opencode try to load THEM as plugins too,
 *      independent of problem 2 above.
 *
 * WHY IT STAYS A SHIM ON V2
 * ----------------------------
 * V2's loader validates only the module's `default` export against
 * `{ id, setup }` (or `{ id, effect }`) and no longer calls named exports, so
 * the crash mode above is gone. The shim is kept anyway: it makes "the
 * discovered module's export surface is exactly `default`" a structural
 * invariant of the install layout rather than a property that happens to hold
 * for the current loader, and it keeps the V1 and V2 entrypoints in one place.
 * `Object.keys(await import("./index.ts"))` is `["default"]`.
 *
 * INSTALL LAYOUT
 * ----------------
 * The adapter's code directory sits BESIDE the discovery directory, never
 * inside it: `.opencode/apexyard/` by convention, produced by
 * `bin/install-opencode-adapter.sh` rather than a hand-copy dance. Every file
 * this adapter needs (this entry, `gate-dispatcher.ts`, `derive-gates.ts`,
 * `resolve-ops-root.ts`, and a sibling copy of the shared
 * `derive-gates-core.ts`) ships there, and the helpers are ordinary relative
 * imports that no discovery scan visits.
 *
 * `.opencode/plugins/apexyard.ts` is the ONLY discovered file. It re-exports
 * `../apexyard/index.ts`, so its own export surface is exactly `default`.
 *
 * The separation is load-bearing on opencode 2.x, which discovers
 * `<discovery>/<name>/index.ts` as well as top-level files: with the code in
 * tree, opencode loaded the adapter twice and ran every gate twice (#2072).
 * opencode 1.x discovers top-level files only, so the shim is its entry too.
 *
 * The default export itself is a V2 plugin definition — `{ id, setup }`,
 * declared in `gate-dispatcher.ts` — because opencode 2.x rejects a bare
 * V1-style `async (input) => hooks` factory with `Plugin must export a default
 * definition with an id and an effect or setup function`.
 */

export { default } from "./gate-dispatcher.ts";

/**
 * index.ts — the ONE file pi's `.pi/extensions/<subdir>/` auto-discovery
 * loads out of an installed adapter subdirectory (me2resh/apexyard#844).
 *
 * THE BUG THIS FILE FIXES
 * -------------------------
 * pi's local-extension discovery scans `.pi/extensions/` for `.ts` files —
 * both directly (top-level `.ts` files) and one level down, one `index.ts`
 * entry per subdirectory. Every file it finds must
 * export a valid factory function as its DEFAULT export, or the whole pi
 * session fails to start: `Error: Failed to load extension
 * ".../resolve-ops-root.ts": Extension does not export a valid factory
 * function`.
 *
 * `gate-dispatcher.ts` already satisfies that contract on its own (it has a
 * clean default export). The live-verified failure (#844) was never
 * gate-dispatcher.ts — it was the documented install instructions copying
 * its SIBLING helper files (`resolve-ops-root.ts`, `derive-gates.ts`, and
 * — after #840 C5 — the shared `derive-gates-core.ts`) FLAT alongside it
 * into the very same `.pi/extensions/` directory pi scans. Those files
 * export named functions/types, no default at all — pi tries to load every
 * one of them as an independent extension, and the whole session aborts
 * before a single gate can enforce anything.
 *
 * THE FIX IS INSTALL LAYOUT, NOT DISPATCH LOGIC
 * -------------------------------------------------
 * Every file this adapter needs (this shim, `gate-dispatcher.ts`,
 * `derive-gates.ts`, `resolve-ops-root.ts`, and a sibling copy of the
 * shared `derive-gates-core.ts`) ships inside ONE subdirectory —
 * `.pi/extensions/apexyard/` by convention, produced by
 * `bin/install-pi-adapter.sh` rather than a hand-copy dance. pi's
 * subdirectory discovery only looks for `index.ts` per subdir (verified
 * live against pi 0.80.3 — see #844), so the helper files sit there as
 * ordinary relative imports the discovery scan never independently visits.
 *
 * This is a re-export SHIM rather than `gate-dispatcher.ts` itself renamed
 * to `index.ts`, for two reasons: `gate-dispatcher.ts` keeps its own name
 * so tests and `tsc --noEmit` keep importing a stable path, and — more
 * importantly — this shape now matches the opencode adapter's `index.ts`
 * exactly. opencode's loader treats EVERY named export of a discovered
 * file as a candidate plugin factory, not only the default, so a shim
 * exposing ONLY `default` is REQUIRED there (see
 * `harness-adapters/opencode/src/index.ts`'s header comment). Re-export
 * shim is a no-op-safe superset for pi (which only inspects `default`
 * anyway) and load-bearing for opencode — one shape, two runtimes, per
 * this ticket's "same fix shape" instruction.
 *
 * `export { default } from "./gate-dispatcher.ts"` re-exports ONLY
 * gate-dispatcher.ts's default export — none of its named exports
 * (`runGateHook`, `registerGateDispatcher`, `buildPiToolInput`, etc.) leak
 * through this module. `Object.keys(await import("./index.ts"))` is
 * `["default"]`, nothing else — see `test/smoke-install-layout.sh` for the
 * load assertion that checks exactly this.
 */

export { default } from "./gate-dispatcher.ts";

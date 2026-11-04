#!/usr/bin/env bash
# smoke-install-layout.sh — LOAD-ASSERTION test for me2resh/apexyard#844.
#
# WHAT THIS PROVES (and doesn't)
# --------------------------------
# #844 found, live against opencode 1.17.16, that the PREVIOUSLY documented
# install (`mkdir .opencode/plugin && cp src/*.ts .opencode/plugin/`) had
# two independent bugs: the discovery directory is PLURAL
# (`.opencode/plugins/`), not singular; and opencode's loader invokes EVERY
# exported function of a discovered file as if it might be a plugin
# factory, not only the default export — so `gate-dispatcher.ts`'s own
# named helper exports (`execGateHookReal`, `buildToolExecuteBeforeHook`,
# `registerGateDispatcher`, ...) get called directly and crash the server:
# `Error: {"name":"UnknownError","message":"Unexpected server error"}`.
#
# This script builds the REAL, shipped install layout via
# `bin/install-opencode-adapter.sh` (not a hand-assembled fixture that could
# drift from what the script actually produces) into a scratch directory,
# then:
#
#   1. Asserts the discovery directory (`.opencode/plugins/`) contains NO
#      top-level `.ts` files — every adapter file lives one level down,
#      inside the `apexyard/` subdirectory.
#   2. Dynamically imports ONLY `.opencode/plugins/apexyard/index.ts` — the
#      one file opencode's subdirectory discovery would actually load — and
#      asserts the import succeeds (every relative import in the chain:
#      index -> gate-dispatcher -> derive-gates -> derive-gates-core,
#      resolve-ops-root, resolves to a real file) and that its module
#      namespace is EXACTLY `["default"]`. This is the load-bearing
#      assertion for opencode specifically: if index.ts leaked even one
#      more named export, opencode's real loader would try to invoke it —
#      exactly the mechanism that crashed the server in #844.
#   3. Drives that default export the way opencode 2.x's loader does: it
#      must be a DEFINITION OBJECT with a non-empty string `id` and a
#      `setup` function (a bare V1 `async (input) => hooks` factory is
#      rejected with "Plugin must export a default definition with an id and
#      an effect or setup function"). `setup()` is then called against a
#      minimal plugin Context and must register an `execute.before` hook on
#      the tool domain — without that it would load but enforce nothing.
#
# This does NOT re-verify a live, model-driven opencode session (that gap is
# already documented in docs/opencode-adapter.md's "honest breakdown" table
# and is unrelated to install layout) — it verifies the install layout
# itself never reproduces the #844 crash again.
#
# RUN
# ---
#   bash harness-adapters/opencode/test/smoke-install-layout.sh
#
# Requires: node >=22, bash, perl (used by bin/install-opencode-adapter.sh's
# path rewrite).

set -euo pipefail

ADAPTER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_ROOT/../.." && pwd)"

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-opencode-install-smoke.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

FIXTURE_PROJECT="$TMPDIR/project"
FIXTURE_OPS_ROOT="$TMPDIR/ops-root"
mkdir -p "$FIXTURE_PROJECT" "$FIXTURE_OPS_ROOT"
# A minimal, valid ops-root anchor with NO .claude/settings.json — gate
# derivation returns an empty table silently (the documented "nothing to
# enforce" case), keeping this test focused on LOAD, not on gate behavior
# (that's what test/smoke-block-unreviewed-merge.sh already covers).
touch "$FIXTURE_OPS_ROOT/.apexyard-fork"

echo "== Installing via bin/install-opencode-adapter.sh =="
bash "$FRAMEWORK_ROOT/bin/install-opencode-adapter.sh" \
  --root "$FRAMEWORK_ROOT" \
  --target-dir "$FIXTURE_PROJECT/.opencode/plugins"

DISCOVERY_DIR="$FIXTURE_PROJECT/.opencode/plugins"
ENTRY="$DISCOVERY_DIR/apexyard/index.ts"

FAIL=0

echo ""
echo "== Check 1: no top-level .ts files directly under the discovery dir =="
TOP_LEVEL_TS=$(find "$DISCOVERY_DIR" -maxdepth 1 -type f -name '*.ts')
if [ -n "$TOP_LEVEL_TS" ]; then
  echo "FAIL: found top-level .ts file(s) directly under $DISCOVERY_DIR — this is the exact shape that crashed opencode in #844:" >&2
  echo "$TOP_LEVEL_TS" >&2
  FAIL=1
else
  echo "PASS: $DISCOVERY_DIR has no top-level .ts files — every adapter file lives inside apexyard/."
fi

echo ""
echo "== Check 2: apexyard/index.ts exists =="
[ -f "$ENTRY" ] || { echo "FAIL: expected entry not found: $ENTRY" >&2; FAIL=1; }

RUNNER="$TMPDIR/run-load-assertion.mjs"
cat > "$RUNNER" <<'RUNNER_EOF'
import { pathToFileURL } from "node:url";

const [, , entryPath, opsRoot] = process.argv;
const mod = await import(pathToFileURL(entryPath).href);

const keys = Object.keys(mod).sort();
console.log("EXPORT_KEYS:" + JSON.stringify(keys));

// opencode V2's loader validates the default export against
//   { id: string, setup: fn } | { id: string, effect: fn }
// and fails with "Plugin must export a default definition with an id and an
// effect or setup function" otherwise (the exact regression this check now
// guards). A bare V1 `async (input) => hooks` factory fails that schema.
const def = mod.default;
console.log("DEFAULT_IS_OBJECT:" + (def !== null && typeof def === "object"));
console.log("HAS_STRING_ID:" + (typeof def?.id === "string" && def.id.length > 0));
console.log("PLUGIN_ID:" + (def?.id ?? ""));
console.log("HAS_SETUP_OR_EFFECT:" + (typeof def?.setup === "function" || typeof def?.effect === "function"));

// Drive setup() the way opencode does: hand it a plugin Context and capture
// what it registers on the tool domain.
const registered = [];
const ctx = {
  location: { directory: opsRoot },
  tool: {
    hook: async (name, _cb) => {
      registered.push(name);
      return { dispose: async () => {} };
    },
  },
};
if (typeof def?.setup === "function") await def.setup(ctx);
console.log("REGISTERED_HOOKS:" + JSON.stringify(registered.sort()));
console.log("HAS_EXECUTE_BEFORE:" + (registered.includes("execute.before")));
RUNNER_EOF

echo ""
echo "== Check 3: dynamic import + V2 definition/setup drive against the installed apexyard/index.ts =="
# opencode resolves the ops root at plugin-load time (unlike pi, which
# defers to per-tool_call resolution — see gate-dispatcher.ts's header
# comment), so this MUST run hermetically: an ambient APEXYARD_OPS_ROOT
# (e.g. set by a Claude Code dev session working on this very repo) would
# otherwise outrank the fixture ops root this test constructs and silently
# test against the real repo's real settings.json instead.
RUN_NODE=(env -u APEXYARD_OPS_ROOT -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR node)
OUTPUT=$("${RUN_NODE[@]}" "$RUNNER" "$ENTRY" "$FIXTURE_OPS_ROOT")
echo "$OUTPUT"

if ! echo "$OUTPUT" | grep -q '^EXPORT_KEYS:\["default"\]$'; then
  echo "FAIL: expected apexyard/index.ts's module namespace to be exactly [\"default\"] — the closed export surface is the structural invariant that kept the #844 crash from recurring, and it is the entry point opencode's loader validates" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^DEFAULT_IS_OBJECT:true$'; then
  echo "FAIL: expected the default export to be a plugin DEFINITION OBJECT — a bare function is rejected by opencode 2.x with 'Plugin must export a default definition with an id and an effect or setup function'" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^HAS_STRING_ID:true$'; then
  echo "FAIL: expected the default export to carry a non-empty string \`id\`" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^HAS_SETUP_OR_EFFECT:true$'; then
  echo "FAIL: expected the default export to expose a \`setup\` (or \`effect\`) function" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^HAS_EXECUTE_BEFORE:true$'; then
  echo "FAIL: expected setup() to register an 'execute.before' hook on ctx.tool — without it the plugin loads but enforces nothing" >&2
  FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: the real, shipped install layout (bin/install-opencode-adapter.sh's output) loads cleanly — no top-level helper files in the discovery dir, and apexyard/index.ts default-exports a V2 definition whose setup registers the execute.before gate hook."
  exit 0
fi
exit 1

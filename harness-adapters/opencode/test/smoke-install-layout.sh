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
#   1. Asserts the discovery directory (`.opencode/plugins/`) contains exactly
#      ONE top-level `.ts` file — the `apexyard.ts` shim — and NO `apexyard/`
#      code subdirectory, because opencode 2.x discovers
#      `<discovery>/<name>/index.ts` as well (#2072).
#   2. Dynamically imports ONLY the code entry (`.opencode/apexyard/index.ts`) — the
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
# and is unrelated to install layout) — it verifies the install layout itself
# never reproduces the #844 crash again, and that the installer leaves exactly
# one discovered entry (#2072).
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
ENTRY="$DISCOVERY_DIR/apexyard.ts"
CODE_DIR="$FIXTURE_PROJECT/.opencode/apexyard"
SUB_ENTRY="$CODE_DIR/index.ts"

FAIL=0

echo ""
echo "== Check 1: exactly one top-level .ts file (the apexyard.ts shim) under the discovery dir, and no code subdirectory there =="
# opencode 1.x loads only top-level files (glob {plugin,plugins}/*.{ts,js});
# 2.x also loads <discovery>/<name>/index.ts. The code directory therefore
# sits BESIDE the discovery dir: with it inside, opencode loads the adapter
# twice and runs every gate twice (me2resh/apexyard#2072).
TOP_LEVEL_TS=$(find "$DISCOVERY_DIR" -maxdepth 1 -type f -name '*.ts' | sort)
EXPECTED_SHIM="$DISCOVERY_DIR/apexyard.ts"
if [ "$TOP_LEVEL_TS" != "$EXPECTED_SHIM" ]; then
  echo "FAIL: expected exactly $EXPECTED_SHIM as the only top-level .ts file, found:" >&2
  echo "$TOP_LEVEL_TS" >&2
  FAIL=1
elif [ -d "$DISCOVERY_DIR/apexyard" ]; then
  echo "FAIL: $DISCOVERY_DIR/apexyard still exists — opencode 2.x discovers its index.ts and loads the adapter twice" >&2
  FAIL=1
elif [ "$(cat "$EXPECTED_SHIM")" != 'export { default } from "../apexyard/index.ts";' ]; then
  echo "FAIL: unexpected shim content in $EXPECTED_SHIM" >&2
  FAIL=1
else
  echo "PASS: apexyard.ts is the only top-level .ts file, the code dir sits outside the discovery dir, and the shim re-exports it."
fi

echo ""
echo "== Check 2: the code entry exists beside the discovery dir =="
[ -f "$SUB_ENTRY" ] || { echo "FAIL: expected entry not found: $SUB_ENTRY" >&2; FAIL=1; }

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
// Dual support (#1956 AC1/AC6): the same object must also expose V1's server().
console.log("HAS_V1_SERVER:" + (typeof def?.server === "function"));

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
if ! echo "$OUTPUT" | grep -q '^HAS_V1_SERVER:true$'; then
  echo "FAIL: expected the default export to expose the V1 server() member — opencode 1.3.4+ calls that instead of setup(), so without it the 1.x path regresses" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^HAS_EXECUTE_BEFORE:true$'; then
  echo "FAIL: expected setup() to register an 'execute.before' hook on ctx.tool — without it the plugin loads but enforces nothing" >&2
  FAIL=1
fi

echo ""
echo "== Check 4: the installer refuses symlinks on the install path and never writes through them =="
INSTALLER="$FRAMEWORK_ROOT/bin/install-opencode-adapter.sh"
# 4a: apexyard.ts is a symlink to a file outside the project.
P4A="$TMPDIR/sym-shim"
mkdir -p "$P4A/.opencode/plugins"
printf 'ORIGINAL\n' > "$TMPDIR/victim-4a"
ln -s "$TMPDIR/victim-4a" "$P4A/.opencode/plugins/apexyard.ts"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P4A/.opencode/plugins" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a symlinked apexyard.ts" >&2; FAIL=1
elif [ "$(cat "$TMPDIR/victim-4a")" != "ORIGINAL" ]; then
  echo "FAIL: installer wrote through the apexyard.ts symlink" >&2; FAIL=1
else
  echo "PASS: symlinked apexyard.ts refused, target untouched."
fi
# 4b: .opencode/plugins is a symlink.
P4B="$TMPDIR/sym-plugins"
mkdir -p "$P4B/.opencode" "$TMPDIR/real-plugins"
ln -s "$TMPDIR/real-plugins" "$P4B/.opencode/plugins"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P4B/.opencode/plugins" >/dev/null 2>&1 || [ -e "$TMPDIR/real-plugins/apexyard.ts" ]; then
  echo "FAIL: installer wrote through a symlinked plugins dir" >&2; FAIL=1
else
  echo "PASS: symlinked plugins dir refused."
fi
# 4c: .opencode is a symlink.
P4C="$TMPDIR/sym-opencode"
mkdir -p "$P4C" "$TMPDIR/real-opencode/plugins"
ln -s "$TMPDIR/real-opencode" "$P4C/.opencode"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P4C/.opencode/plugins" >/dev/null 2>&1 || [ -e "$TMPDIR/real-opencode/plugins/apexyard.ts" ]; then
  echo "FAIL: installer wrote through a symlinked .opencode dir" >&2; FAIL=1
else
  echo "PASS: symlinked .opencode dir refused."
fi
# 4d: the code directory itself is a symlink.
P4D="$TMPDIR/sym-code-dir"
mkdir -p "$P4D/.opencode/plugins" "$TMPDIR/real-code-dir"
printf 'user code\n' > "$TMPDIR/real-code-dir/user.ts"
ln -s "$TMPDIR/real-code-dir" "$P4D/.opencode/apexyard"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P4D/.opencode/plugins" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a symlinked code directory" >&2; FAIL=1
elif [ ! -f "$TMPDIR/real-code-dir/user.ts" ]; then
  echo "FAIL: installer wrote through the code-directory symlink" >&2; FAIL=1
else
  echo "PASS: symlinked code directory refused, target untouched."
fi
# 4e: the shim path is a directory. mv would drop the temp shim inside it and
# the run would end with no discovered entry.
P4E="$TMPDIR/shim-is-dir"
mkdir -p "$P4E/.opencode/plugins/apexyard.ts"
printf 'operator\n' > "$P4E/.opencode/plugins/apexyard.ts/keep.txt"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P4E/.opencode/plugins" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a directory at the shim path" >&2; FAIL=1
elif [ ! -f "$P4E/.opencode/plugins/apexyard.ts/keep.txt" ]; then
  echo "FAIL: the refused run changed the operator's file in the shim directory" >&2; FAIL=1
elif [ -e "$P4E/.opencode/apexyard" ]; then
  echo "FAIL: the refused run wrote a code directory before checking the shim path" >&2; FAIL=1
else
  echo "PASS: a directory at the shim path is refused before any install writes."
fi

echo ""
echo "== Check 5: re-running the installer on a pre-#2072 install moves the code out and rewrites the shim =="
P5="$TMPDIR/upgrade"
mkdir -p "$P5/.opencode/plugins/apexyard"
: > "$P5/.opencode/plugins/apexyard/index.ts"
printf 'export { default } from "./apexyard/index.ts";\n' > "$P5/.opencode/plugins/apexyard.ts"
bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P5/.opencode/plugins" >/dev/null
if [ "$(cat "$P5/.opencode/plugins/apexyard.ts")" = 'export { default } from "../apexyard/index.ts";' ] \
  && [ -f "$P5/.opencode/apexyard/index.ts" ] \
  && [ ! -e "$P5/.opencode/plugins/apexyard" ]; then
  echo "PASS: upgrade run moved the code directory out of the discovery dir and rewrote the shim."
else
  echo "FAIL: upgrade run did not produce the single-entry layout" >&2; FAIL=1
fi

echo ""
echo "== Check 6: inputs that would destroy the discovery dir or a neighbour are refused =="
# --name equal to the discovery dir's own name makes the code path BE the
# discovery dir, and the installer removes that path with rm -rf. It deleted
# every plugin the operator had installed there (#2072 review).
P6="$TMPDIR/name-collision"
mkdir -p "$P6/.opencode/plugins"
printf 'export const mine = 1;\n' > "$P6/.opencode/plugins/operator-plugin.ts"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P6/.opencode/plugins" --name plugins >/dev/null 2>&1; then
  echo "FAIL: installer accepted --name plugins, which collides with the discovery dir" >&2; FAIL=1
elif [ ! -f "$P6/.opencode/plugins/operator-plugin.ts" ]; then
  echo "FAIL: the refused run still deleted the operator's plugin" >&2; FAIL=1
else
  echo "PASS: --name plugins refused and the operator's plugin is intact."
fi
# A target that is not a discovery directory is refused before the code path is
# derived from its parent: `--target-dir .opencode` put the code at
# <project>/apexyard and deleted the operator's own apexyard/ there.
P6B="$TMPDIR/bad-target"
mkdir -p "$P6B/.opencode" "$P6B/apexyard"
printf 'notes\n' > "$P6B/apexyard/notes.md"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P6B/.opencode" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a --target-dir that is not a discovery directory" >&2; FAIL=1
elif [ ! -f "$P6B/apexyard/notes.md" ]; then
  echo "FAIL: the refused run still deleted the operator's apexyard/ directory" >&2; FAIL=1
else
  echo "PASS: a non-discovery --target-dir is refused and its neighbour is intact."
fi
# A name that names an opencode discovery directory is refused. With a singular
# target-dir, `--name plugins` would make the code path the real plural
# discovery dir and the installer would rm -rf every plugin inside it.
P6A="$TMPDIR/reserved-name"
mkdir -p "$P6A/.opencode/plugins"
printf 'export const mine = 1;\n' > "$P6A/.opencode/plugins/operator-plugin.ts"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P6A/.opencode/plugins" --name plugin >/dev/null 2>&1; then
  echo "FAIL: installer accepted --name plugin, which is a discovery directory name" >&2; FAIL=1
elif [ ! -f "$P6A/.opencode/plugins/operator-plugin.ts" ]; then
  echo "FAIL: the refused reserved-name run still deleted the operator's plugin" >&2; FAIL=1
else
  echo "PASS: --name plugin refused and the operator's plugin is intact."
fi
# A '..' segment is refused before any derived path is checked, so a symlinked
# intermediate directory cannot redirect the code or legacy path.
P6D="$TMPDIR/dotdot-target"
mkdir -p "$P6D/.opencode/plugins"
printf 'export const mine = 1;\n' > "$P6D/.opencode/plugins/operator-plugin.ts"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P6D/.opencode/plugins/../plugins" >/dev/null 2>&1; then
  echo "FAIL: installer accepted a --target-dir with a '..' segment" >&2; FAIL=1
elif [ ! -f "$P6D/.opencode/plugins/operator-plugin.ts" ]; then
  echo "FAIL: the refused '..' run still deleted the operator's plugin" >&2; FAIL=1
else
  echo "PASS: a --target-dir with a '..' segment is refused and the operator's plugin is intact."
fi
# A trailing `/.` used to spell the code path two ways, so the legacy removal
# deleted the copy the same run had just written and left a dangling shim.
P6C="$TMPDIR/trailing-dot"
mkdir -p "$P6C/.opencode/plugins"
bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P6C/.opencode/plugins/." >/dev/null
if [ -f "$P6C/.opencode/apexyard/index.ts" ] && [ ! -e "$P6C/.opencode/plugins/apexyard" ]; then
  echo "PASS: a trailing '/.' target still produces the single-entry layout."
else
  echo "FAIL: a trailing '/.' target deleted the code directory or left a second entry" >&2; FAIL=1
fi

echo ""
echo "== Check 7: the installer will not remove a directory it did not write =="
P7="$TMPDIR/foreign-dest"
mkdir -p "$P7/.opencode/plugins" "$P7/.opencode/custom"
printf 'notes\n' > "$P7/.opencode/custom/notes.md"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P7/.opencode/plugins" --name custom >/dev/null 2>&1; then
  echo "FAIL: installer removed a foreign directory at its code path" >&2; FAIL=1
elif [ ! -f "$P7/.opencode/custom/notes.md" ]; then
  echo "FAIL: the refused run still deleted the foreign directory" >&2; FAIL=1
else
  echo "PASS: a foreign directory at the code path is refused and left intact."
fi

echo ""
echo "== Check 8: the installer verifies one discovered entry instead of claiming one =="
P8="$TMPDIR/second-shim"
mkdir -p "$P8/.opencode/plugins"
printf 'export { default } from "../apexyard/index.ts";\n' > "$P8/.opencode/plugins/other.ts"
if bash "$INSTALLER" --root "$FRAMEWORK_ROOT" --target-dir "$P8/.opencode/plugins" >/dev/null 2>&1; then
  echo "FAIL: installer reported success with a second shim re-exporting the same code dir" >&2; FAIL=1
else
  echo "PASS: a second shim is refused instead of reported as a single entry."
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: the real, shipped install layout (bin/install-opencode-adapter.sh's output) loads cleanly — one discovered shim, the code directory outside the discovery dir, and apexyard/index.ts default-exports a V2 definition whose setup registers the execute.before gate hook."
  exit 0
fi
exit 1

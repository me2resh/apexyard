#!/usr/bin/env bash
# smoke-install-layout.sh — LOAD-ASSERTION test for me2resh/apexyard#844.
#
# WHAT THIS PROVES (and doesn't)
# --------------------------------
# #844 found, live against pi 0.80.3, that the PREVIOUSLY documented install
# (`cp gate-dispatcher.ts resolve-ops-root.ts .pi/extensions/`) crashes the
# whole pi session: pi's local-extension discovery loads every `.ts` file it
# finds directly under `.pi/extensions/`, and `resolve-ops-root.ts` — a
# helper module with no default export — fails pi's "does this export a
# valid factory function" check, aborting the session before any gate can
# enforce anything.
#
# This script builds the REAL, shipped install layout via
# `bin/install-pi-adapter.sh` (not a hand-assembled fixture that could drift
# from what the script actually produces) into a scratch directory, then:
#
#   1. Asserts the discovery directory (`.pi/extensions/`) itself contains
#      NO top-level `.ts` files — every adapter file lives one level down,
#      inside the `apexyard/` subdirectory, which is what fixes the bug.
#   2. Dynamically imports ONLY `.pi/extensions/apexyard/index.ts` — the one
#      file pi's subdirectory discovery would actually load — and asserts
#      the import succeeds (proving every relative import in the chain:
#      index -> gate-dispatcher -> derive-gates -> derive-gates-core,
#      resolve-ops-root, resolves to a real file) and that its module
#      namespace is EXACTLY `["default"]`, a function.
#   3. Calls that default export the way pi calls an extension factory
#      (`extension(pi)`), with a minimal mock `ExtensionAPI`, and asserts it
#      registers a `"tool_call"` handler without throwing — proving the
#      whole chain is not just importable but actually runs.
#
# This does NOT re-verify a live, model-driven pi session (that gap is
# already documented in README.md's "Known gaps" section and is unrelated
# to install layout) — it verifies the install layout itself never
# reproduces the #844 crash again.
#
# RUN
# ---
#   bash harness-adapters/pi/test/smoke-install-layout.sh
#
# Requires: node >=22, bash, perl (used by bin/install-pi-adapter.sh's path
# rewrite).

set -euo pipefail

ADAPTER_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_ROOT="$(cd "$ADAPTER_ROOT/../.." && pwd)"

TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-pi-install-smoke.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

FIXTURE_PROJECT="$TMPDIR/project"
mkdir -p "$FIXTURE_PROJECT"

echo "== Installing via bin/install-pi-adapter.sh =="
bash "$FRAMEWORK_ROOT/bin/install-pi-adapter.sh" \
  --root "$FRAMEWORK_ROOT" \
  --target-dir "$FIXTURE_PROJECT/.pi/extensions"

DISCOVERY_DIR="$FIXTURE_PROJECT/.pi/extensions"
ENTRY="$DISCOVERY_DIR/apexyard/index.ts"

FAIL=0

echo ""
echo "== Check 1: no top-level .ts files directly under the discovery dir =="
TOP_LEVEL_TS=$(find "$DISCOVERY_DIR" -maxdepth 1 -type f -name '*.ts')
if [ -n "$TOP_LEVEL_TS" ]; then
  echo "FAIL: found top-level .ts file(s) directly under $DISCOVERY_DIR — this is the exact shape that crashed pi in #844:" >&2
  echo "$TOP_LEVEL_TS" >&2
  FAIL=1
else
  echo "PASS: $DISCOVERY_DIR has no top-level .ts files — every adapter file lives inside apexyard/."
fi

echo ""
echo "== Check 2: apexyard/index.ts exists and is the only sibling with a default export used at discovery time =="
[ -f "$ENTRY" ] || { echo "FAIL: expected entry not found: $ENTRY" >&2; FAIL=1; }

RUNNER="$TMPDIR/run-load-assertion.mjs"
cat > "$RUNNER" <<'RUNNER_EOF'
import { pathToFileURL } from "node:url";

const [, , entryPath] = process.argv;
const mod = await import(pathToFileURL(entryPath).href);

const keys = Object.keys(mod).sort();
console.log("EXPORT_KEYS:" + JSON.stringify(keys));
console.log("DEFAULT_IS_FUNCTION:" + (typeof mod.default === "function"));

let registeredEvent = null;
const fakePi = { on: (event) => { registeredEvent = event; } };
mod.default(fakePi);
console.log("REGISTERED_EVENT:" + registeredEvent);
RUNNER_EOF

echo ""
echo "== Check 3: dynamic import + factory call against the installed apexyard/index.ts =="
# pi's dispatcher only resolves an ops root INSIDE its tool_call handler
# (per-call resolution — see gate-dispatcher.ts's header comment), which
# this test never triggers (it only registers the handler), so an ambient
# APEXYARD_OPS_ROOT can't affect this check today. Scrubbed anyway so this
# stays true if that timing ever changes — same discipline
# smoke-block-unreviewed-merge.sh and the opencode sibling of this script
# already apply.
RUN_NODE=(env -u APEXYARD_OPS_ROOT -u CLAUDE_CODE_SESSION_ID -u APEXYARD_OPS_PIN_DIR node)
OUTPUT=$("${RUN_NODE[@]}" "$RUNNER" "$ENTRY")
echo "$OUTPUT"

if ! echo "$OUTPUT" | grep -q '^EXPORT_KEYS:\["default"\]$'; then
  echo "FAIL: expected apexyard/index.ts's module namespace to be exactly [\"default\"] — a leaked named export is exactly what would let pi's loader (or a future stricter one) try to invoke a non-factory helper" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^DEFAULT_IS_FUNCTION:true$'; then
  echo "FAIL: expected the default export to be a function (pi's own crash mode: 'does not export a valid factory function')" >&2
  FAIL=1
fi
if ! echo "$OUTPUT" | grep -q '^REGISTERED_EVENT:tool_call$'; then
  echo "FAIL: expected calling the default export with a mock pi ExtensionAPI to register a 'tool_call' handler" >&2
  FAIL=1
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: the real, shipped install layout (bin/install-pi-adapter.sh's output) loads cleanly — no top-level helper files in the discovery dir, and apexyard/index.ts exports only a working default factory."
  exit 0
fi
exit 1

#!/usr/bin/env bash
# Install the apexyard opencode gate adapter into a project's local
# `.opencode/plugins/` directory (PLURAL — see below), in the ONLY layout
# that loads cleanly in a real opencode session (me2resh/apexyard#844).
#
# WHY THIS SCRIPT EXISTS, NOT JUST DOCS
# ----------------------------------------
# Two independent bugs in the previously-documented install, both confirmed
# live against opencode 1.17.16:
#
#   1. The discovery directory is PLURAL — `.opencode/plugins/` — not the
#      singular `.opencode/plugin/` earlier docs used. The singular form
#      silently loads nothing.
#   2. opencode's loader treats EVERY exported function of a discovered
#      file as a candidate plugin factory, not only its default export. The
#      adapter's real implementation, `gate-dispatcher.ts`, exports several
#      named helpers alongside its default plugin
#      (`execGateHookReal`, `buildToolExecuteBeforeHook`,
#      `registerGateDispatcher`, ...) — placed directly in the discovery
#      dir, opencode calls each of those as if it might be a plugin
#      factory and crashes the whole server at startup. Copying its
#      SIBLING helper modules (`derive-gates.ts`, `resolve-ops-root.ts`,
#      and — since #840 C5 — the shared `derive-gates-core.ts`) into the
#      same directory makes opencode try to load THEM as plugins too.
#
# The fix is an install LAYOUT, not a dispatch-logic change: every file
# this adapter needs lives inside one subdirectory, with a re-export SHIM
# (`index.ts` — the ONLY file exporting anything, and its only export is
# the default plugin) as the sole discovered entry. See
# `harness-adapters/opencode/src/index.ts`'s header comment for the full
# mechanism. This script produces that layout mechanically instead of
# asking an adopter to hand-copy files into the right shape (and dir name)
# every time.
#
# This script also rewrites the one import line in the installed copy of
# `derive-gates.ts` that points at the shared core two directories up
# (`../../_shared/derive-gates-core.ts`, correct from inside this repo's
# own `harness-adapters/opencode/src/`) to a same-directory import
# (`./derive-gates-core.ts`, correct once the file sits flat inside the
# installed subdirectory alongside its own copy of derive-gates-core.ts) —
# the same technique `bin/sync-codex-adapter.sh` already uses when
# generating Codex's adapter files from `.claude/`, applied to a different
# target shape. See `bin/install-pi-adapter.sh` for the pi-flavored sibling
# of this script; the two are near-identical except for the discovery
# directory name and default target path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR=""
NAME="apexyard"

usage() {
  cat <<'USAGE'
Usage: bin/install-opencode-adapter.sh [--target-dir <path>] [--name <subdir>] [--root <path>]

Installs the apexyard opencode gate adapter (gate-dispatcher.ts + its
helper modules) into <target-dir>/<name>/, the layout opencode's local
plugin discovery loads cleanly (a single index.ts entry per subdirectory,
whose only export is the default plugin).

Options:
  --target-dir PATH  Directory opencode scans for plugins.
                      Defaults to "<cwd>/.opencode/plugins" (PLURAL — see
                      this script's header comment) — run this script from
                      the project you want opencode to enforce gates in.
  --name NAME         Subdirectory name under --target-dir. Default: apexyard.
  --root PATH         Path to the apexyard ops fork (where harness-adapters/
                       lives). Defaults to this script's own repo root.
  -h, --help          Show this help.

Example (installing into the current project's own working tree):
  bash /path/to/apexyard/bin/install-opencode-adapter.sh
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --target-dir requires a path" >&2; exit 2; }
      TARGET_DIR="$2"
      shift
      ;;
    --name)
      [ "$#" -ge 2 ] || { echo "ERROR: --name requires a value" >&2; exit 2; }
      NAME="$2"
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

ROOT="$(cd "$ROOT" && pwd)"
ADAPTER_SRC="$ROOT/harness-adapters/opencode/src"
SHARED_CORE="$ROOT/harness-adapters/_shared/derive-gates-core.ts"
[ -z "$TARGET_DIR" ] && TARGET_DIR="$(pwd)/.opencode/plugins"

for f in index.ts gate-dispatcher.ts derive-gates.ts resolve-ops-root.ts; do
  [ -f "$ADAPTER_SRC/$f" ] || { echo "ERROR: expected source file not found: $ADAPTER_SRC/$f" >&2; exit 1; }
done
[ -f "$SHARED_CORE" ] || { echo "ERROR: expected shared-core file not found: $SHARED_CORE" >&2; exit 1; }

DEST="$TARGET_DIR/$NAME"
rm -rf "$DEST"
mkdir -p "$DEST"

cp "$ADAPTER_SRC/index.ts" "$DEST/index.ts"
cp "$ADAPTER_SRC/gate-dispatcher.ts" "$DEST/gate-dispatcher.ts"
cp "$ADAPTER_SRC/resolve-ops-root.ts" "$DEST/resolve-ops-root.ts"
cp "$ADAPTER_SRC/derive-gates.ts" "$DEST/derive-gates.ts"
cp "$SHARED_CORE" "$DEST/derive-gates-core.ts"

# Rewrite the one import in the installed derive-gates.ts copy that pointed
# two directories up at the shared core in this repo's own tree — inside
# the installed subdirectory, derive-gates-core.ts is now a flat sibling.
perl -0pi -e 's{\.\./\.\./_shared/derive-gates-core\.ts}{./derive-gates-core.ts}g' "$DEST/derive-gates.ts"

# Only the IMPORT SPECIFIER matters here — doc comments mentioning the
# original repo path ("harness-adapters/_shared/derive-gates-core.ts") are
# expected to survive the copy unchanged and are not a broken-import signal.
if grep -Eq '\.\./\.\./_shared/derive-gates-core\.ts' "$DEST/derive-gates.ts"; then
  echo "ERROR: failed to rewrite the shared-core import path in $DEST/derive-gates.ts — refusing to ship a broken copy" >&2
  echo "       (the import specifier in harness-adapters/opencode/src/derive-gates.ts may have changed shape; update this script's rewrite pattern)" >&2
  exit 1
fi
if ! grep -Eq 'from ["'"'"']\./derive-gates-core\.ts["'"'"']' "$DEST/derive-gates.ts"; then
  echo "ERROR: expected a same-directory import of derive-gates-core.ts in $DEST/derive-gates.ts after rewrite, found none — refusing to ship a broken copy" >&2
  exit 1
fi

if [ "$(basename "$TARGET_DIR")" = "plugin" ]; then
  echo "WARNING: --target-dir ends in the singular 'plugin' — opencode's real, live-verified discovery dir is PLURAL ('plugins'). Continuing, but opencode will not find this install unless '$TARGET_DIR' is itself scanned." >&2
fi

echo "Installed the apexyard opencode gate adapter:"
echo "  $DEST/index.ts               <- opencode's ONLY discovered entry for this subdirectory"
echo "  $DEST/gate-dispatcher.ts"
echo "  $DEST/resolve-ops-root.ts"
echo "  $DEST/derive-gates.ts"
echo "  $DEST/derive-gates-core.ts"
echo ""
echo "Next: (cd \"$ROOT/harness-adapters/opencode\" && npm install)"
echo "Then run opencode from the project containing $TARGET_DIR — it auto-discovers $DEST/index.ts."

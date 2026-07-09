#!/usr/bin/env bash
# Install the apexyard pi gate adapter into a project's local
# `.pi/extensions/` directory, in the ONLY layout that loads cleanly in a
# real pi session (me2resh/apexyard#844).
#
# WHY THIS SCRIPT EXISTS, NOT JUST DOCS
# ----------------------------------------
# The adapter's implementation is `harness-adapters/pi/src/gate-dispatcher.ts`
# plus three sibling modules it imports: `derive-gates.ts`,
# `resolve-ops-root.ts`, and (since #840 C5) the shared, cross-adapter
# `harness-adapters/_shared/derive-gates-core.ts`. pi's local-extension
# discovery scans `.pi/extensions/` for `.ts` files and requires every ONE
# it finds to export a valid factory function as its default export — a
# flat `cp` of all four files into that directory (the install shape #844
# found crashing live against pi 0.80.3) makes pi try to load every helper
# file as an independent extension and fail the whole session. The fix is
# an install LAYOUT, not a code change: every file this adapter needs lives
# inside one subdirectory pi never scans past `index.ts` (see
# `harness-adapters/pi/src/index.ts`'s header comment for the full
# mechanism). This script produces that layout mechanically instead of
# asking an adopter to hand-copy four files into the right shape and get it
# right every time.
#
# One thing this script DOES that a plain multi-file `cp` cannot: it
# rewrites the one import line in the installed copy of `derive-gates.ts`
# that points at the shared core two directories up
# (`../../_shared/derive-gates-core.ts`, correct from inside this repo's own
# `harness-adapters/pi/src/`) to a same-directory import
# (`./derive-gates-core.ts`, correct once the file sits flat inside the
# installed subdirectory alongside its own copy of derive-gates-core.ts).
# This mirrors the path-rewriting `bin/sync-codex-adapter.sh` already does
# when it generates Codex's adapter files from `.claude/` — same technique,
# applied to a different target shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR=""
NAME="apexyard"

usage() {
  cat <<'USAGE'
Usage: bin/install-pi-adapter.sh [--target-dir <path>] [--name <subdir>] [--root <path>]

Installs the apexyard pi gate adapter (gate-dispatcher.ts + its helper
modules) into <target-dir>/<name>/, the layout pi's local-extension
discovery loads cleanly (a single index.ts entry per subdirectory).

Options:
  --target-dir PATH  Directory pi scans for extensions.
                      Defaults to "<cwd>/.pi/extensions" — run this script
                      from the project you want pi to enforce gates in.
  --name NAME         Subdirectory name under --target-dir. Default: apexyard.
  --root PATH         Path to the apexyard ops fork (where harness-adapters/
                       lives). Defaults to this script's own repo root.
  -h, --help          Show this help.

Example (installing into the current project's own working tree):
  bash /path/to/apexyard/bin/install-pi-adapter.sh
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
ADAPTER_SRC="$ROOT/harness-adapters/pi/src"
SHARED_CORE="$ROOT/harness-adapters/_shared/derive-gates-core.ts"
[ -z "$TARGET_DIR" ] && TARGET_DIR="$(pwd)/.pi/extensions"

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
  echo "       (the import specifier in harness-adapters/pi/src/derive-gates.ts may have changed shape; update this script's rewrite pattern)" >&2
  exit 1
fi
if ! grep -Eq 'from ["'"'"']\./derive-gates-core\.ts["'"'"']' "$DEST/derive-gates.ts"; then
  echo "ERROR: expected a same-directory import of derive-gates-core.ts in $DEST/derive-gates.ts after rewrite, found none — refusing to ship a broken copy" >&2
  exit 1
fi

echo "Installed the apexyard pi gate adapter:"
echo "  $DEST/index.ts               <- pi's ONLY discovered entry for this subdirectory"
echo "  $DEST/gate-dispatcher.ts"
echo "  $DEST/resolve-ops-root.ts"
echo "  $DEST/derive-gates.ts"
echo "  $DEST/derive-gates-core.ts"
echo ""
echo "Next: cd $(dirname "$ROOT/harness-adapters/pi") >/dev/null; (cd \"$ROOT/harness-adapters/pi\" && npm install)"
echo "Then run pi from the project containing $TARGET_DIR — it auto-discovers $DEST/index.ts."

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
# this adapter needs lives inside one subdirectory OUTSIDE the discovery
# directory, with a re-export SHIM in the discovery directory as the sole
# discovered entry. The shim's only export is the default plugin. The code
# directory sits beside `.opencode/plugins/`, not inside it, because
# opencode 2.x also discovers `<discovery>/<subdir>/index.ts`: keeping the
# code inside the discovery directory made opencode load the adapter twice
# and run every gate twice (me2resh/apexyard#2072). Older opencode 1.x
# discovers top-level files only, so the shim stays the entry there too.
# See `harness-adapters/opencode/src/index.ts`'s header comment for the
# full mechanism. This script produces that layout mechanically instead of
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
#
# WHAT IT INSTALLS SERVES BOTH PLUGIN GENERATIONS
# ------------------------------------------------
# The shipped `index.ts` default-exports one object: `{ id, setup }` for
# opencode 2.x, plus `server()` for the object entrypoint opencode 1.3.4+
# accepts. `setup` registers `ctx.tool.hook("execute.before", …)`; `server`
# returns the V1 `{ "tool.execute.before": … }` hooks. The script warns only
# when the `opencode` on PATH predates 1.3.4, the first release verified to
# load an object entrypoint. 1.3.3 and earlier require a factory function and
# fail with "fn3 is not a function".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR=""
NAME="apexyard"

usage() {
  cat <<'USAGE'
Usage: bin/install-opencode-adapter.sh [--target-dir <path>] [--name <subdir>] [--root <path>]

Installs the apexyard opencode gate adapter (gate-dispatcher.ts + its
helper modules) into <parent>/<name>/, where <parent> is the directory
that CONTAINS the plugin discovery dir. The discovery dir gets a single
top-level shim file (<name>.ts) that re-exports the subdirectory entry.
Keeping the code directory outside the discovery dir stops opencode 2.x
from loading the adapter a second time through <discovery>/<name>/index.ts.

Options:
  --target-dir PATH  Directory opencode scans for plugins. It must be named
                      "plugins" (or the singular "plugin", which opencode
                      does not scan — a warning prints). Defaults to
                      "<cwd>/.opencode/plugins" (PLURAL — see this script's
                      header comment) — run this script from the project you
                      want opencode to enforce gates in.
  --name NAME         Subdirectory name beside the discovery dir. Default:
                      apexyard. It must differ from the discovery dir's own
                      name, and the installer refuses to delete a directory at
                      that path that is not one of its own installs.
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

# Resolve the target to ONE spelling before anything is derived from it. The
# legacy-directory removal below decides by string comparison, so `plugins/.`
# and `plugins` would compare unequal, and the second spelling would delete the
# copy this same run had just written (#2072 review).
while :; do
  case "$TARGET_DIR" in
    */) TARGET_DIR="${TARGET_DIR%/}" ;;
    */.) TARGET_DIR="${TARGET_DIR%/.}" ;;
    *) break ;;
  esac
done
case "$TARGET_DIR" in
  /*) ;;
  *) TARGET_DIR="$PWD/$TARGET_DIR" ;;
esac

case "$TARGET_DIR" in
  ..|../*|*/..|*/../*)
    echo "ERROR: --target-dir must not contain a '..' path segment (got: '$TARGET_DIR')." >&2
    echo "       A '..' segment can change the derived parent and code paths after the symlink checks run." >&2
    exit 2
    ;;
esac

case "$(basename "$TARGET_DIR")" in
  plugins|plugin) ;;
  *)
    echo "ERROR: --target-dir must be opencode's plugin discovery directory, which is named 'plugins' (got: '$TARGET_DIR')." >&2
    echo "       The code directory is installed BESIDE it, so any other name puts the code where opencode never looks." >&2
    exit 2
    ;;
esac

# The install path is deleted with `rm -rf "$DEST"` below, so a blank or
# path-escaping --name must be rejected. So must a name that collapses onto the
# directory it is derived from: `--name plugins` with the default --target-dir
# makes $DEST the discovery dir itself, and the rm -rf would then delete every
# plugin the adopter installed there.
case "$NAME" in
  ""|.|..|*/*)
    echo "ERROR: --name must be a single non-empty path segment (got: '$NAME') — it is removed with rm -rf under the target dir." >&2
    exit 2
    ;;
esac
case "$NAME" in
  *[!A-Za-z0-9._-]*)
    echo "ERROR: --name may contain only letters, digits, '.', '_' and '-' (got: '$NAME')." >&2
    exit 2
    ;;
esac
if [ "$NAME" = "$(basename "$TARGET_DIR")" ]; then
  echo "ERROR: --name '$NAME' is the discovery directory's own name — that would put the code inside the directory opencode scans." >&2
  echo "       Pass a different --name, for example the default 'apexyard'." >&2
  exit 2
fi
# opencode also scans the singular `plugin` directory. A code directory with
# either reserved name is itself a second plugin source, and with a singular
# --target-dir it is the plural discovery dir the installer would rm -rf.
case "$NAME" in
  plugin|plugins)
    echo "ERROR: --name '$NAME' names an opencode plugin discovery directory. Pass a different --name, for example the default 'apexyard'." >&2
    exit 2
    ;;
esac

# The code lives beside the discovery directory, never inside it: opencode 2.x
# also discovers `<discovery>/<name>/index.ts`, so an in-tree subdirectory is
# loaded a second time and every gate runs twice (#2072). Only the shim file
# sits in the discovery directory.
CODE_PARENT="$(dirname "$TARGET_DIR")"
DEST="$CODE_PARENT/$NAME"
SHIM="$TARGET_DIR/$NAME.ts"
LEGACY_DEST="$TARGET_DIR/$NAME"

# Refuse symlinks on the install path. The shim is written into $TARGET_DIR,
# and a symlink there could redirect the write to a file outside the project
# (for example a gate hook). The same holds for the parent .opencode dir and
# the code directory.
for link_path in "$CODE_PARENT" "$TARGET_DIR" "$DEST" "$SHIM"; do
  if [ -L "$link_path" ]; then
    echo "ERROR: refusing to install: $link_path is a symlink. Remove it or install into a real directory." >&2
    exit 1
  fi
done
# mv would move the temp shim INTO this directory instead of replacing the
# path, leaving zero discovered entries after the legacy directory was removed.
if [ -d "$SHIM" ]; then
  echo "ERROR: refusing to install: $SHIM is a directory, not a shim file." >&2
  echo "       Move it aside so the installer can write the single discovered entry." >&2
  exit 1
fi

# $DEST and $LEGACY_DEST are removed with rm -rf, so only remove a directory
# this installer wrote. A directory at either path with no adapter entry at
# index.ts is the operator's; deleting it is data loss. A single-segment
# --target-dir reaches the project root, where an `apexyard/` of the operator's
# own is a plausible neighbour.
for owned in "$DEST" "$LEGACY_DEST"; do
  if [ -e "$owned" ] && [ ! -f "$owned/index.ts" ]; then
    echo "ERROR: refusing to remove $owned: it exists and is not an apexyard adapter install." >&2
    echo "       Move it aside, or pass a different --name." >&2
    exit 1
  fi
done

for f in index.ts gate-dispatcher.ts derive-gates.ts resolve-ops-root.ts; do
  [ -f "$ADAPTER_SRC/$f" ] || { echo "ERROR: expected source file not found: $ADAPTER_SRC/$f" >&2; exit 1; }
done
[ -f "$SHARED_CORE" ] || { echo "ERROR: expected shared-core file not found: $SHARED_CORE" >&2; exit 1; }

DEST="$CODE_PARENT/$NAME"
rm -rf "$DEST"
mkdir -p "$DEST" "$TARGET_DIR"

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

# Write the shim BEFORE removing the legacy in-tree directory. If the removal
# fails, `set -e` stops the run with the shim already pointing at the new code
# directory and the old entry still present: opencode then loads the adapter
# twice (the original #2072 symptom), which is the safer failure — gates still
# run. Removing first could leave the old shim pointing at a deleted directory
# and no gates at all. opencode 1.x discovers top-level files only
# (`{plugin,plugins}/*.{ts,js}`) and 2.x discovers both those and
# `<discovery>/<name>/index.ts`, so this file is the single entry under both.
# The shim re-exports the code directory beside the discovery dir, and its
# only export is the default plugin (the #844 crash cannot recur).
# Write to a temp file in the same directory and rename it into place: mv
# replaces the path itself and never follows a symlink. Re-running the
# installer adds the shim to an older install.
SHIM_TMP="$(mktemp "$TARGET_DIR/.apexyard-shim.XXXXXX")"
printf 'export { default } from "../%s/index.ts";\n' "$NAME" > "$SHIM_TMP"
chmod 644 "$SHIM_TMP"
mv -f "$SHIM_TMP" "$SHIM"

# The shim now points at the new code directory, so removing the legacy
# in-tree directory can no longer leave the install with zero gates. The
# single-entry check below still fails the run if this removal does not
# happen, so a legacy directory never passes silently.
if [ "$LEGACY_DEST" != "$DEST" ] && [ -d "$LEGACY_DEST" ]; then
  rm -rf "$LEGACY_DEST"
fi

# #2072 asks the installer to VERIFY a single entry, not to claim one. Count the
# discovered files that re-export THIS install: a second shim is a second plugin
# instance, and an in-tree code directory is the 2.x second entry. Other plugins
# in the same directory belong to the operator and are not counted here.
shims=0
for discovered in "$TARGET_DIR"/*.ts "$TARGET_DIR"/*.js; do
  if [ -f "$discovered" ] && grep -Fq "from \"../$NAME/index.ts\"" "$discovered"; then
    shims=$((shims + 1))
  fi
done
if [ -d "$TARGET_DIR/$NAME" ]; then
  echo "ERROR: $TARGET_DIR/$NAME still exists — opencode 2.x discovers its index.ts and loads the adapter twice (#2072)." >&2
  exit 1
fi
if [ "$shims" -ne 1 ]; then
  echo "ERROR: expected exactly one shim re-exporting ../$NAME/index.ts in $TARGET_DIR, found $shims — opencode would load $shims adapter instances (#2072)." >&2
  exit 1
fi

if [ "$(basename "$TARGET_DIR")" = "plugin" ]; then
  echo "WARNING: --target-dir ends in the singular 'plugin' — opencode's real, live-verified discovery dir is PLURAL ('plugins'). Continuing, but opencode will not find this install unless '$TARGET_DIR' is itself scanned." >&2
fi

# The adapter serves BOTH plugin generations from one default export: a
# `{ id, setup }` definition for opencode 2.x, plus a `server()` member for
# the object entrypoint opencode 1.3.4+ accepts. 1.3.3 and earlier require a
# factory function, so they cannot load this object entrypoint at all. Warn
# about that at install time rather than leaving it to a "failed to load
# plugin" WARN in the server log.
if command -v opencode >/dev/null 2>&1; then
  # Real output is a bare version ("1.17.16") on 1.x and a prefixed version
  # ("opencode v2.1.4") on 2.x. Accept both; the old pattern required the
  # prefix, so the warning never fired on a real 1.x install.
  OC_VERSION="$(opencode --version 2>/dev/null | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
  case "${OC_VERSION:-}" in
    ''|*[!0-9.]*) : ;; # unparseable/absent version — say nothing rather than guess
    *)
      OC_MAJOR="${OC_VERSION%%.*}"
      OC_REST="${OC_VERSION#*.}"
      OC_MINOR="${OC_REST%%.*}"
      OC_PATCH="${OC_REST#*.}"
      if [ "$OC_MAJOR" -lt 1 ] || { [ "$OC_MAJOR" -eq 1 ] && { [ "$OC_MINOR" -lt 3 ] || { [ "$OC_MINOR" -eq 3 ] && [ "$OC_PATCH" -lt 4 ]; }; }; }; then
        echo "WARNING: the 'opencode' on PATH reports $OC_VERSION, which predates 1.3.4." >&2
        echo "         This adapter serves opencode 1.x through the object entrypoint's server() member," >&2
        echo "         and 1.3.4 is the first release verified to load an object entrypoint. Upgrade opencode." >&2
      fi
      ;;
  esac
fi

echo "Installed the apexyard opencode gate adapter:"
echo "  $SHIM          <- the only file opencode discovers (shim)"
echo "  $DEST/index.ts               <- the real entry, re-exported by the shim"
echo "  $DEST/gate-dispatcher.ts"
echo "  $DEST/resolve-ops-root.ts"
echo "  $DEST/derive-gates.ts"
echo "  $DEST/derive-gates-core.ts"
echo ""
echo "The code directory sits beside $TARGET_DIR, not inside it, so opencode"
echo "loads the adapter once (me2resh/apexyard#2072)."
echo ""
echo "Next: (cd \"$ROOT/harness-adapters/opencode\" && npm install)"
echo "Then run opencode from the project containing $TARGET_DIR — it loads $SHIM."

#!/usr/bin/env bash
# Install the apexyard Cursor gate adapter into Cursor's USER-level hooks
# config — the ONLY location Cursor 3.x actually loads
# (me2resh/apexyard#840 finding #3). A project-level `.cursor/hooks.json`
# (what `bin/sync-cursor-adapter.sh` writes without --user) showed
# "Configured Hooks (0)" in a live Cursor.app 3.10.20 session — never
# loaded, no trust prompt. Installing the identical, unmodified generated
# hooks into `~/.cursor/hooks.json` showed "Configured Hooks (1)" and it
# blocked a real `git add .` in an agent turn. Schema (`version:1`,
# `beforeShellExecution`, `failClosed`) was already correct; only the
# location was wrong.
#
# WHY THIS SCRIPT EXISTS, NOT JUST bin/sync-cursor-adapter.sh
# ----------------------------------------------------------------
# bin/sync-cursor-adapter.sh owns the jq generation pipeline (the
# event-mapping table, the beforeShellExecution stdin remap, the
# failClosed list) — this script does not fork or re-implement any of
# that gate logic. It reuses the exact same generator, in its `--user`
# mode, which MERGES the generated hooks.json into the user config
# instead of writing a project file: existing entries in
# ~/.cursor/hooks.json that this framework did not generate (the user's
# own hooks, or a different tool's) are left untouched; only apexyard's
# own entries (identified structurally — every one execs a
# `.claude/hooks/*.sh` script, see owned_hooks_only() in
# bin/sync-cursor-adapter.sh) are replaced. This wrapper adds the
# install-lifecycle ergonomics a raw `sync-cursor-adapter.sh --user` call
# doesn't have on its own: a documented default target, a --uninstall
# path, and a friendly summary of what changed.
#
# SCOPE NOTE — this is a per-machine (per-OS-user) install, unlike the
# pi/opencode adapters (installed per-PROJECT into that project's
# .pi/extensions/ or .opencode/plugins/). Cursor's hook loader reads one
# ~/.cursor/hooks.json and applies it across every project you open in
# Cursor. That is safe here because every generated hook command still
# self-scopes: it resolves ops-root by walking up from Cursor's cwd for
# an `.apexyard-fork` marker (or a live session pin) and exits 0
# immediately if the current project isn't apexyard-governed (see the
# CURSOR_SHELL_REMAP shim in bin/sync-cursor-adapter.sh) — so installing
# once does not force apexyard's gates onto unrelated Cursor projects.
#
# KNOWN LIMITATION (me2resh/apexyard#840 finding #4) — even once loaded,
# a live Cursor.app 3.10.20 agent turn could not be confirmed to cleanly
# EXECUTE the delegated bash hook (`MainThreadShellExec not initialized`
# was reported, instrumentation never fired). The observed block came
# from `failClosed: true` denying the action after the hook-runner
# errored, not from the gate logic evaluating and returning exit 2. This
# is weaker than the opencode/pi adapters, where the delegated bash
# genuinely runs. See docs/cursor-adapter.md § Known Limitations before
# relying on this for anything beyond "known-bad commands get blocked."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_DIR="${HOME:-}/.cursor"
UNINSTALL=0

usage() {
  cat <<'USAGE'
Usage: bin/install-cursor-adapter.sh [--root <path>] [--user-dir <path>] [--uninstall]

Merges the apexyard Cursor gate adapter into Cursor's USER-level hooks
config (~/.cursor/hooks.json by default) — the location Cursor 3.x
actually loads (me2resh/apexyard#840). Also writes/refreshes the
project-level .cursor/rules/apexyard.mdc advisory bridge in --root.

Options:
  --root PATH      Path to the apexyard ops fork (where bin/sync-cursor-adapter.sh
                    and .claude/ live). Defaults to this script's own repo root.
                    Run this from within the project whose .cursor/rules/apexyard.mdc
                    you also want refreshed; the hooks.json merge itself is
                    machine-wide, not project-scoped (see this script's header).
  --user-dir PATH  Override the user Cursor config directory (default
                    $HOME/.cursor). Mainly for testing — never point this at
                    a real $HOME in a test.
  --uninstall      Remove ONLY apexyard's own entries from <user-dir>/hooks.json
                    (identified structurally, not by hand-picked event) —
                    every other hook already in that file is left alone. A
                    timestamped backup is written first. Does not touch the
                    project .cursor/rules/apexyard.mdc; remove that yourself
                    (or `rm -rf .cursor`) if you also want it gone.
  -h, --help       Show this help.

Example (install into the current machine's Cursor, refreshing this project's
rules bridge):
  bash /path/to/apexyard/bin/install-cursor-adapter.sh

Example (uninstall):
  bash /path/to/apexyard/bin/install-cursor-adapter.sh --uninstall
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    --user-dir)
      [ "$#" -ge 2 ] || { echo "ERROR: --user-dir requires a path" >&2; exit 2; }
      USER_DIR="$2"
      shift
      ;;
    --uninstall)
      UNINSTALL=1
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

if [ -z "$USER_DIR" ]; then
  echo "ERROR: \$HOME is not set; pass --user-dir explicitly" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to install the Cursor adapter safely" >&2
  exit 1
fi

if [ "$UNINSTALL" = "1" ]; then
  TARGET="$USER_DIR/hooks.json"
  if [ ! -f "$TARGET" ]; then
    echo "Nothing to uninstall: $TARGET does not exist."
    exit 0
  fi
  if ! jq empty "$TARGET" >/dev/null 2>&1; then
    echo "ERROR: $TARGET is not valid JSON; refusing to modify it automatically. Inspect it by hand." >&2
    exit 1
  fi

  BEFORE_COUNT=$(jq '[(.hooks // {})[]?[]?] | length' "$TARGET")
  BACKUP="$TARGET.bak-$(date +%Y%m%d%H%M%S)"
  cp "$TARGET" "$BACKUP"

  jq '
    .hooks = (
      (.hooks // {})
      | with_entries(.value |= map(select(((.command // "") | test("\\.claude/hooks/")) | not)))
      | with_entries(select(.value | length > 0))
    )
  ' "$TARGET" > "$TARGET.tmp"
  mv "$TARGET.tmp" "$TARGET"

  AFTER_COUNT=$(jq '[(.hooks // {})[]?[]?] | length' "$TARGET")
  REMOVED=$((BEFORE_COUNT - AFTER_COUNT))

  echo "Removed $REMOVED apexyard-managed hook entr$([ "$REMOVED" = 1 ] && echo y || echo ies) from $TARGET"
  echo "Backup saved at $BACKUP (restore with: cp \"$BACKUP\" \"$TARGET\")"
  echo "Restart Cursor (or reload the window) for the change to take effect."
  exit 0
fi

ROOT="$(cd "$ROOT" && pwd)"
[ -x "$ROOT/bin/sync-cursor-adapter.sh" ] || { echo "ERROR: $ROOT/bin/sync-cursor-adapter.sh not found or not executable" >&2; exit 1; }

if "$ROOT/bin/sync-cursor-adapter.sh" --user --user-dir "$USER_DIR" --root "$ROOT"; then
  echo ""
  echo "Restart Cursor (or reload the window) to pick up the change — Cursor"
  echo "reads ~/.cursor/hooks.json at startup, not live."
  echo ""
  echo "KNOWN LIMITATION (me2resh/apexyard#840): on Cursor 3.10.20 the delegated"
  echo "bash hook did not appear to execute cleanly in agent mode"
  echo "(MainThreadShellExec not initialized). The observed block came from"
  echo "failClosed denying the action after the hook-runner errored, not from"
  echo "the gate logic evaluating. See docs/cursor-adapter.md § Known Limitations."
  echo ""
  echo "cursor-agent (the CLI) is NOT covered by this adapter — it enforces via"
  echo "its own ~/.cursor/cli-config.json permissions model, not hooks.json."
else
  exit 1
fi

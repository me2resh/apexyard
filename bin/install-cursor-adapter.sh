#!/usr/bin/env bash
# Install the thin Cursor overlay into Cursor USER-level hooks config.
#
# Native-first (AgDR-0151): Cursor loads `.claude/settings.json` hooks when
# third-party configs are enabled. This script does not copy those gates.
# It merges the sessionStart pin overlay into ~/.cursor/hooks.json and
# refreshes `.cursor/rules/apexyard.mdc`.
#
# WHY THIS SCRIPT EXISTS, NOT JUST bin/sync-cursor-adapter.sh
# ----------------------------------------------------------------
# bin/sync-cursor-adapter.sh owns generation of the overlay. This wrapper
# adds install-lifecycle ergonomics: a documented default target, a
# --uninstall path, and a summary of what changed.
#
# --user merge replaces leftover full generated adapters. Any command
# that execs `.claude/hooks/*.sh` is apexyard-owned. Re-install strips
# those copies and writes the thin overlay. Foreign hooks stay.
#
# SCOPE NOTE — this is a per-machine (per-OS-user) install. Cursor's
# user hooks.json applies across every project. The overlay still
# self-scopes: it walks for an `.apexyard-fork` marker (or a live
# session pin) and prints {} if the current project is not governed.
#
# Native gate execution needs Settings → Rules, Skills, Subagents →
# Include third-party Plugins, Skills, and other configs. Without that
# toggle, `.claude/settings.json` does not load.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_DIR="${HOME:-}/.cursor"
UNINSTALL=0

usage() {
  cat <<'USAGE'
Usage: bin/install-cursor-adapter.sh [--root <path>] [--user-dir <path>] [--uninstall]

Merges the thin apexyard Cursor overlay into Cursor's USER-level hooks
config (~/.cursor/hooks.json by default). Also writes/refreshes the
project-level .cursor/rules/apexyard.mdc advisory bridge in --root.

The overlay maps Cursor session_id onto CLAUDE_CODE_SESSION_ID. Canonical
gates load from .claude/settings.json when third-party configs are on.

Options:
  --root PATH      Path to the apexyard ops fork (where bin/sync-cursor-adapter.sh
                    and .claude/ live). Defaults to this script's own repo root.
                    Run this from within the project whose .cursor/rules/apexyard.mdc
                    you also want refreshed. The hooks.json merge itself is
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
  echo "Restart Cursor (or reload the window) to pick up the change. Cursor"
  echo "reads ~/.cursor/hooks.json at startup, not live."
  echo ""
  echo "Enable Settings → Rules, Skills, Subagents → Include third-party"
  echo "Plugins, Skills, and other configs so .claude/settings.json gates load."
  echo "A leftover full generated adapter can fail-closed-block every Shell"
  echo "or Write call. Re-install replaces that copy with the thin overlay."
  echo ""
  echo "cursor-agent (the CLI) is NOT covered by this overlay. It enforces via"
  echo "its own ~/.cursor/cli-config.json permissions model, not hooks.json."
else
  exit 1
fi

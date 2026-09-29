#!/usr/bin/env bash
# List skill names Cursor would load from a workspace (apexyard#1377).
#
# Usage:
#   bin/list-cursor-skills.sh [--root <path>] [--unique | --duplicates]
#
# Default prints path<TAB>name<TAB>kind for every discovered SKILL.md.
# --unique prints path<TAB>name with override-wins dedupe.
# --duplicates prints duplicate names and exits 1 when any exist.

set -euo pipefail

ROOT="."
MODE="discover"

usage() {
  cat <<'USAGE'
Usage: bin/list-cursor-skills.sh [--root <path>] [--unique | --duplicates]

List skill entries Cursor would load from a workspace when third-party
configs are on. Used to prove override skills do not appear twice.

Options:
  --root PATH     Workspace root to scan (default: cwd).
  --unique        Print one path per skill name. Override wins.
  --duplicates    Print duplicate skill names. Exit 1 when any exist.
  -h, --help      Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "ERROR: --root requires a path" >&2; exit 2; }
      ROOT="$2"
      shift
      ;;
    --unique) MODE="unique" ;;
    --duplicates) MODE="duplicates" ;;
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
LIB="$(cd "$(dirname "$0")/.." && pwd)/.claude/hooks/_lib-cursor-skills.sh"
# shellcheck source=/dev/null
. "$LIB"

case "$MODE" in
  unique) cursor_skills_unique "$ROOT" ;;
  duplicates) cursor_skills_duplicate_names "$ROOT" ;;
  *) cursor_skills_discover "$ROOT" ;;
esac

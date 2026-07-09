#!/usr/bin/env bash
# snapshot-diff.sh — filesystem contamination detector for /eval-agents.
#
# Snapshots a directory's file set before an agent-under-test spawn, then
# checks it after. Any new, changed, or deleted file is flagged. This is the
# authoritative contamination check (SKILL.md Step 3c/3e, #833) — a stronger
# backstop than scanning the agent's returned text for a marker-write
# confession, because a silent Bash-redirect write never has to appear in
# narrated output for this check to catch it.
#
# Usage:
#   snapshot-diff.sh snapshot <dir> <snapshot-file>
#   snapshot-diff.sh check    <dir> <snapshot-file>
#
# `snapshot` records a manifest of <dir>'s current file set (relative path +
# sha256, one per line, sorted) to <snapshot-file>. `check` re-scans <dir>
# and reports any file that's NEW, CHANGED (different hash), or DELETED
# since the snapshot was taken.
#
# Exit codes:
#   0 — no contamination (dir unchanged since snapshot)
#   1 — contamination detected (each affected path + reason printed to stdout)
#   2 — usage error (bad args, or `check` with no prior `snapshot`)

set -euo pipefail
export LC_ALL=C   # deterministic sort/comm collation regardless of locale

MODE="${1:-}"
DIR="${2:-}"
SNAPSHOT_FILE="${3:-}"

usage() {
  echo "usage: snapshot-diff.sh <snapshot|check> <dir> <snapshot-file>" >&2
  exit 2
}

[ -n "$MODE" ] && [ -n "$DIR" ] && [ -n "$SNAPSHOT_FILE" ] || usage

sha_of() {
  # Portable sha256: shasum on macOS, sha256sum on Linux.
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

manifest_of() {
  # Emits "<relpath>  <sha256>" for every regular file under $DIR, sorted.
  # Creates $DIR if missing — a fresh session may have no reviews/ dir yet,
  # and "the directory doesn't exist" is not itself contamination.
  mkdir -p "$DIR"
  find "$DIR" -type f 2>/dev/null | sort | while IFS= read -r f; do
    rel="${f#"$DIR"/}"
    echo "$rel  $(sha_of "$f")"
  done
}

case "$MODE" in
  snapshot)
    manifest_of > "$SNAPSHOT_FILE"
    ;;
  check)
    if [ ! -f "$SNAPSHOT_FILE" ]; then
      echo "snapshot-diff.sh: no snapshot at $SNAPSHOT_FILE — run 'snapshot' first" >&2
      exit 2
    fi
    CURRENT="$(mktemp)"
    trap 'rm -f "$CURRENT"' EXIT
    manifest_of > "$CURRENT"

    if diff -q "$SNAPSHOT_FILE" "$CURRENT" >/dev/null 2>&1; then
      echo "OK — no changes to $DIR since snapshot"
      exit 0
    fi

    echo "CONTAMINATION — $DIR changed since snapshot:"
    path_in() {
      # $1 = path, $2 = manifest file — fixed-string match on the "path  " prefix
      grep -qF "$1  " "$2" 2>/dev/null
    }

    # Lines only in CURRENT (new content, or a path whose hash changed).
    comm -13 "$SNAPSHOT_FILE" "$CURRENT" | while IFS= read -r line; do
      path="${line%%  *}"
      if path_in "$path" "$SNAPSHOT_FILE"; then
        echo "  CHANGED: $path"
      else
        echo "  NEW:     $path"
      fi
    done

    # Lines only in SNAPSHOT and whose path is genuinely gone from CURRENT
    # (not just hash-changed — that case was already reported as CHANGED above).
    comm -23 "$SNAPSHOT_FILE" "$CURRENT" | while IFS= read -r line; do
      path="${line%%  *}"
      if ! path_in "$path" "$CURRENT"; then
        echo "  DELETED: $path"
      fi
    done

    exit 1
    ;;
  *)
    usage
    ;;
esac

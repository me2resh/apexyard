#!/bin/bash
# Release ownership after a /fan-out writer task succeeds.
# Run from the orchestrating session that prepared the worktree.
# This helper preserves the worktree directory and branch.

set -u

WTPATH="${1:-}"
if [ "$#" -ne 1 ] || [ -z "$WTPATH" ]; then
  printf 'usage: release-worktree-owner.sh <worktree-path>\n' >&2
  exit 2
fi

HOOK_DIR=$(CDPATH='' cd "$(dirname "$0")/../../hooks" && pwd) || exit 1
if [ ! -f "$HOOK_DIR/_lib-worktree-owner.sh" ]; then
  printf 'refused %s: unknown\n' "$WTPATH"
  exit 1
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-worktree-owner.sh"

if worktree_owner_release "$WTPATH" >/dev/null 2>&1; then
  printf 'released %s\n' "$WTPATH"
  exit 0
fi

# Status codes distinguish absent and released records from unknown liveness.
# Malformed records also return unknown. Keep the library's uncertainty.
status=$(worktree_owner_status "$WTPATH" 2>/dev/null) || :
case "$status" in
  released) printf 'already released %s\n' "$WTPATH"; exit 0 ;;
  none) printf 'no owner record %s\n' "$WTPATH"; exit 0 ;;
  alive|dead|unknown) ;;
  *) status=unknown ;;
esac
printf 'refused %s: %s\n' "$WTPATH" "$status"
exit 1

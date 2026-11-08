#!/bin/bash
# SessionStart startup and compact both restore the current tree's note.
HOOK_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=/dev/null
. "$HOOK_DIR/_lib-progress-note.sh"
input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cwd" ] || cwd=$PWD
progress_note_print "$cwd"
exit 0

#!/bin/bash
set -u
INPUT_FILE=$(mktemp)
trap 'rm -f "$INPUT_FILE"' EXIT
cat > "$INPUT_FILE"
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
run() {
  local hook="$1"
  [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || return 0
  "$HOOK_DIR/$hook" < "$INPUT_FILE" || exit $?
}
run auto-code-review.sh
run warn-stale-review-markers.sh
run suggest-mcp-reindex-after-clone.sh
run suggest-mcp-reindex-after-pull.sh

#!/bin/bash
set -u
INPUT=$(cat)
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"

payloads_for_input() {
  local tool
  tool=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
  case "$tool" in
    apply_patch|Edit|Write|MultiEdit) ;;
    *) printf '%s' "$INPUT" | jq -c . 2>/dev/null || printf '%s\n' "$INPUT"; return 0 ;;
  esac

  local direct
  direct=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
  if [ -n "$direct" ]; then
    printf '%s' "$INPUT" | jq -c . 2>/dev/null || printf '%s\n' "$INPUT"
    return 0
  fi

  local patch paths
  patch=$(printf '%s' "$INPUT" | jq -r '.tool_input.patch // .tool_input.input // empty' 2>/dev/null)
  paths=$(printf '%s\n' "$patch" | awk '
    /^\*\*\* (Add|Update|Delete) File: / { sub(/^\*\*\* (Add|Update|Delete) File: /, ""); print; next }
    /^\*\*\* Move to: / { sub(/^\*\*\* Move to: /, ""); print; next }
  ' | sort -u)
  if [ -n "$paths" ]; then
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      jq -nc --arg path "$path" '{tool_name:"Write", tool_input:{file_path:$path}}'
    done <<EOF_PATHS
$paths
EOF_PATHS
    return 0
  fi

  printf '%s' "$INPUT" | jq -c . 2>/dev/null || printf '%s\n' "$INPUT"
}

run_for_payload() {
  local payload="$1" hook
  for hook in require-migration-ticket.sh require-active-ticket.sh detect-role-trigger.sh warn-review-marker-write.sh; do
    [ -x "$HOOK_DIR/$hook" ] || [ -f "$HOOK_DIR/$hook" ] || continue
    printf '%s' "$payload" | "$HOOK_DIR/$hook" || return $?
  done
}

set -o pipefail
payloads_for_input | while IFS= read -r payload; do
  [ -n "$payload" ] || continue
  run_for_payload "$payload" || exit $?
done

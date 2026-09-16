#!/usr/bin/env bash
# Cursor sessionStart overlay: map Cursor session_id onto CLAUDE_CODE_SESSION_ID
# and write the ops-root pin that every other hook already reads.
#
# Native-first Cursor loading (AgDR-0151) runs the canonical .claude hooks
# through Cursor's Claude Code loader. Those hooks still look up
# CLAUDE_CODE_SESSION_ID. Cursor sessionStart stdin carries session_id
# instead. This overlay is the only generated Cursor hook: it fills that
# gap and injects env for later hooks in the same session.
#
# Stdout MUST be JSON only. Cursor sessionStart is fire-and-forget for
# blocking, but it does consume env and additional_context.
#
# Silent no-ops (print {}):
#   - current tree is not an apexyard fork
#   - no session id in stdin or env
#   - pin-ops-root.sh missing

set -u

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOOK_DIR/_lib-ops-root.sh"
PIN="$HOOK_DIR/pin-ops-root.sh"

emit_empty() {
  printf '%s\n' '{}'
  exit 0
}

input=$(cat || true)

session_id=""
if command -v jq >/dev/null 2>&1; then
  session_id=$(printf '%s' "$input" | jq -r '.session_id // .conversation_id // empty' 2>/dev/null || true)
elif command -v python3 >/dev/null 2>&1; then
  session_id=$(SESSION_PIN_INPUT="$input" python3 -c '
import json, os
raw = os.environ.get("SESSION_PIN_INPUT") or ""
try:
    data = json.loads(raw) if raw else {}
except json.JSONDecodeError:
    data = {}
print(data.get("session_id") or data.get("conversation_id") or "")
' 2>/dev/null || true)
fi

if [ -z "$session_id" ]; then
  session_id="${CLAUDE_CODE_SESSION_ID:-}"
fi

if [ -z "$session_id" ]; then
  emit_empty
fi

if [ ! -f "$LIB" ] || [ ! -f "$PIN" ]; then
  emit_empty
fi

# shellcheck source=/dev/null
. "$LIB"

start_dir="${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
ops_root=$(resolve_ops_root_walk "$start_dir")
if [ -z "$ops_root" ]; then
  emit_empty
fi

export CLAUDE_CODE_SESSION_ID="$session_id"
(
  cd "$ops_root" || exit 0
  # pin-ops-root.sh reads CLAUDE_CODE_SESSION_ID and walks $PWD.
  bash "$PIN" >/dev/null
)

if command -v jq >/dev/null 2>&1; then
  jq -n --arg sid "$session_id" '{env:{CLAUDE_CODE_SESSION_ID:$sid}}'
else
  printf '{"env":{"CLAUDE_CODE_SESSION_ID":"%s"}}\n' "$session_id"
fi
exit 0
